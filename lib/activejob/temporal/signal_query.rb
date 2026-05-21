# frozen_string_literal: true

require "temporalio/error"
require_relative "workflow_id_builder"

module ActiveJob
  module Temporal
    module SignalQuery
      UUID_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      JOB_CLASS_NAME_PATTERN = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/
      HANDLER_NAME_PATTERN = /\A[a-zA-Z_]\w*\z/
      DEFAULT_REJECT_CONDITION = Object.new.freeze

      class << self
        def signal(job_class, job_id, signal_name, *)
          validate_job_class!(job_class)
          validate_job_id!(job_id)
          handler_name = normalize_handler_name!(signal_name, "signal")

          with_running_workflow_handle(job_class, job_id) do |handle|
            handle.signal(handler_name, *)
          end
        rescue ArgumentError, ActiveJob::Temporal::WorkflowNotFoundError
          raise
        rescue StandardError => e
          raise ActiveJob::Temporal::TemporalConnectionError,
                "Failed to signal Temporal workflow for job_id #{job_id}: #{e.message}"
        end

        def query(job_class, job_id, query_name, *args, reject_condition: DEFAULT_REJECT_CONDITION)
          validate_job_class!(job_class)
          validate_job_id!(job_id)
          handler_name = normalize_handler_name!(query_name, "query")

          with_running_workflow_handle(job_class, job_id) do |handle|
            query_workflow(handle, handler_name, args, reject_condition)
          end
        rescue ArgumentError, ActiveJob::Temporal::WorkflowNotFoundError
          raise
        rescue StandardError => e
          raise if workflow_query_error?(e)

          raise ActiveJob::Temporal::TemporalConnectionError,
                "Failed to query Temporal workflow for job_id #{job_id}: #{e.message}"
        end

        private

        def with_running_workflow_handle(job_class, job_id)
          client = ActiveJob::Temporal.client
          default_handle = client.workflow_handle(default_workflow_id(job_class, job_id), run_id: nil)

          begin
            return yield(default_handle)
          rescue StandardError => e
            raise unless rpc_not_found?(e)
          end

          workflow_reference = find_running_workflow_reference(client, job_class, job_id)
          raise workflow_not_found(job_id) unless workflow_reference

          fallback_handle = client.workflow_handle(
            workflow_reference.fetch(:workflow_id),
            run_id: workflow_reference[:run_id]
          )
          begin
            yield(fallback_handle)
          rescue StandardError => e
            raise workflow_not_found(job_id) if rpc_not_found?(e)

            raise
          end
        end

        def query_workflow(handle, handler_name, args, reject_condition)
          if reject_condition.equal?(DEFAULT_REJECT_CONDITION)
            handle.query(handler_name, *args)
          else
            handle.query(handler_name, *args, reject_condition: reject_condition)
          end
        end

        def find_running_workflow_reference(client, job_class, job_id)
          workflow = client.list_workflows(workflow_search_query(job_class, job_id)).first
          return unless workflow

          {
            workflow_id: workflow.id,
            run_id: workflow.respond_to?(:run_id) ? workflow.run_id : nil
          }
        rescue StandardError => e
          return nil if rpc_invalid_argument?(e)

          raise
        end

        def validate_job_class!(job_class)
          unless job_class.is_a?(Class) && !job_class.name.to_s.empty?
            raise ArgumentError, "job_class must be a named class"
          end

          return if job_class.name.match?(JOB_CLASS_NAME_PATTERN)

          raise ArgumentError, "job_class must have a valid constant name"
        end

        def validate_job_id!(job_id)
          return if job_id.is_a?(String) && job_id.match?(UUID_REGEX)

          raise ArgumentError,
                "Invalid job_id format: expected UUID (e.g., '550e8400-e29b-41d4-a716-446655440000'), " \
                "got: #{job_id.inspect}"
        end

        def normalize_handler_name!(name, handler_type)
          handler_name = name.to_s
          return handler_name if handler_name.match?(HANDLER_NAME_PATTERN)

          raise ArgumentError, "#{handler_type} names must start with a letter or underscore and contain word chars"
        end

        def workflow_search_query(job_class, job_id)
          "ajClass='#{job_class.name}' AND ajJobId='#{job_id}' AND ExecutionStatus='Running'"
        end

        def default_workflow_id(job_class, job_id)
          WorkflowIdBuilder.new.build_from_job_class(job_class, job_id)
        end

        def workflow_not_found(job_id)
          ActiveJob::Temporal::WorkflowNotFoundError.new(
            "No running workflow found for job_id #{job_id}. The job may have completed or never existed."
          )
        end

        def workflow_query_error?(error)
          query_failed_error?(error) || query_rejected_error?(error)
        end

        def query_failed_error?(error)
          defined?(Temporalio::Error::WorkflowQueryFailedError) &&
            error.is_a?(Temporalio::Error::WorkflowQueryFailedError)
        end

        def query_rejected_error?(error)
          defined?(Temporalio::Error::WorkflowQueryRejectedError) &&
            error.is_a?(Temporalio::Error::WorkflowQueryRejectedError)
        end

        def rpc_not_found?(error)
          defined?(Temporalio::Error::RPCError) &&
            error.is_a?(Temporalio::Error::RPCError) &&
            error.code == Temporalio::Error::RPCError::Code::NOT_FOUND
        end

        def rpc_invalid_argument?(error)
          defined?(Temporalio::Error::RPCError) &&
            error.is_a?(Temporalio::Error::RPCError) &&
            error.code == Temporalio::Error::RPCError::Code::INVALID_ARGUMENT
        end
      end
    end
  end
end
