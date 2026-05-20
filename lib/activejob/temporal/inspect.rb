# frozen_string_literal: true

require "temporalio/client/workflow_execution_status"
require "temporalio/error"
require_relative "workflow_id_builder"

module ActiveJob
  module Temporal
    module Inspect
      UUID_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      JOB_CLASS_NAME_PATTERN = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/
      WORKFLOW_STATES = {
        Temporalio::Client::WorkflowExecutionStatus::RUNNING => :running,
        Temporalio::Client::WorkflowExecutionStatus::COMPLETED => :completed,
        Temporalio::Client::WorkflowExecutionStatus::FAILED => :failed,
        Temporalio::Client::WorkflowExecutionStatus::CANCELED => :canceled,
        Temporalio::Client::WorkflowExecutionStatus::TERMINATED => :terminated,
        Temporalio::Client::WorkflowExecutionStatus::CONTINUED_AS_NEW => :continued_as_new,
        Temporalio::Client::WorkflowExecutionStatus::TIMED_OUT => :timed_out
      }.freeze

      class << self
        def status(job_class, job_id)
          validate_job_class!(job_class)
          validate_job_id!(job_id)

          client = ActiveJob::Temporal.client
          describe_default_workflow(client, job_class, job_id) ||
            describe_search_attribute_workflow(client, job_class, job_id)
        rescue ArgumentError
          raise
        rescue StandardError => e
          raise ActiveJob::Temporal::TemporalConnectionError,
                "Failed to inspect Temporal workflow for job_id #{job_id}: #{e.message}"
        end

        def running?(job_class, job_id) = workflow_state?(job_class, job_id, :running)

        def completed?(job_class, job_id) = workflow_state?(job_class, job_id, :completed)

        def failed?(job_class, job_id) = workflow_state?(job_class, job_id, :failed)

        private

        def workflow_state?(job_class, job_id, state)
          status(job_class, job_id)&.fetch(:state) == state
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

        def describe_default_workflow(client, job_class, job_id)
          describe_workflow(client, default_workflow_reference(job_class, job_id))
        rescue StandardError => e
          raise unless rpc_not_found?(e)

          nil
        end

        def describe_search_attribute_workflow(client, job_class, job_id)
          workflow_reference = find_workflow_reference(client, job_class, job_id)
          return unless workflow_reference

          describe_workflow(client, workflow_reference)
        rescue StandardError => e
          return nil if rpc_not_found?(e) || rpc_invalid_argument?(e)

          raise
        end

        def find_workflow_reference(client, job_class, job_id)
          workflow = client.list_workflows(workflow_search_query(job_class, job_id)).first
          return unless workflow

          {
            workflow_id: workflow.id,
            run_id: workflow.respond_to?(:run_id) ? workflow.run_id : nil
          }
        end

        def workflow_search_query(job_class, job_id)
          "ajClass='#{job_class.name}' AND ajJobId='#{job_id}'"
        end

        def default_workflow_reference(job_class, job_id)
          {
            workflow_id: WorkflowIdBuilder.new.build_from_job_class(job_class, job_id),
            run_id: nil
          }
        end

        def describe_workflow(client, workflow_reference)
          handle = client.workflow_handle(
            workflow_reference.fetch(:workflow_id),
            run_id: workflow_reference[:run_id]
          )
          status_from_description(handle.describe)
        end

        def status_from_description(description)
          pending_activity = pending_activity(description)

          {
            state: WORKFLOW_STATES.fetch(description.status, :unknown),
            workflow_id: description.id,
            run_id: description.run_id,
            started_at: description.start_time,
            closed_at: description.close_time,
            attempt: activity_attempt(pending_activity),
            last_failure: activity_last_failure(pending_activity)
          }
        end

        def pending_activity(description)
          return unless description.respond_to?(:raw_description)
          return unless description.raw_description.respond_to?(:pending_activities)

          activities = description.raw_description.pending_activities
          return if activities.nil? || activities.empty?

          activities.max_by { |activity| activity_attempt(activity).to_i }
        end

        def activity_attempt(activity)
          return unless activity.respond_to?(:attempt)

          activity.attempt
        end

        def activity_last_failure(activity)
          return unless activity.respond_to?(:last_failure)

          format_failure(activity.last_failure)
        end

        def format_failure(failure)
          return unless failure

          type = failure_type(failure)
          message = failure.respond_to?(:message) ? failure.message.to_s : failure.to_s
          failure_details = [type, message].compact.reject(&:empty?)
          return if failure_details.empty?

          failure_details.join(": ")
        end

        def failure_type(failure)
          return unless failure.respond_to?(:application_failure_info)
          return unless failure.application_failure_info.respond_to?(:type)

          failure.application_failure_info.type.to_s
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
