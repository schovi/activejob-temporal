# frozen_string_literal: true

require "temporalio/activity"
require "temporalio/client/workflow_execution_status"
require "temporalio/error"

require_relative "../workflow_id_builder"

module ActiveJob
  module Temporal
    module Activities
      class DependencyStatusActivity < Temporalio::Activity::Definition
        SAFE_QUERY_VALUE_PATTERN = /\A[A-Za-z0-9_.:-]+\z/
        WORKFLOW_STATES = {
          Temporalio::Client::WorkflowExecutionStatus::RUNNING => "running",
          Temporalio::Client::WorkflowExecutionStatus::COMPLETED => "completed",
          Temporalio::Client::WorkflowExecutionStatus::FAILED => "failed",
          Temporalio::Client::WorkflowExecutionStatus::CANCELED => "canceled",
          Temporalio::Client::WorkflowExecutionStatus::TERMINATED => "terminated",
          Temporalio::Client::WorkflowExecutionStatus::CONTINUED_AS_NEW => "continued_as_new",
          Temporalio::Client::WorkflowExecutionStatus::TIMED_OUT => "timed_out"
        }.freeze

        def execute(dependencies)
          Array(dependencies).map { |dependency| status_for(normalize_dependency(dependency)) }
        end

        private

        def status_for(dependency)
          workflow_reference = find_workflow_reference(dependency)
          return status_payload(dependency, "not_found") unless workflow_reference

          status_from_description(dependency, describe_workflow(workflow_reference))
        rescue StandardError => e
          fallback_description = describe_search_attribute_workflow(dependency) if rpc_not_found?(e)
          return status_from_description(dependency, fallback_description) if fallback_description
          return status_payload(dependency, "not_found") if rpc_not_found?(e) || rpc_invalid_argument?(e)

          raise
        end

        def status_from_description(dependency, description)
          status_payload(
            dependency,
            WORKFLOW_STATES.fetch(description.status, "unknown"),
            workflow_id: description.id,
            run_id: description.run_id
          )
        end

        def normalize_dependency(dependency)
          dependency.each_with_object({}) do |(key, value), normalized|
            normalized[key.to_s] = value
          end
        end

        def find_workflow_reference(dependency)
          workflow_id = dependency["workflow_id"]
          return { workflow_id: workflow_id, run_id: nil } if workflow_id

          search_workflow_reference(dependency) || default_workflow_reference(dependency)
        end

        def search_workflow_reference(dependency)
          job_id = dependency["job_id"]
          return unless job_id

          workflow = client.list_workflows(workflow_search_query(dependency)).first
          return unless workflow

          {
            workflow_id: workflow.id,
            run_id: workflow.respond_to?(:run_id) ? workflow.run_id : nil
          }
        rescue StandardError => e
          return nil if rpc_invalid_argument?(e)

          raise
        end

        def default_workflow_reference(dependency)
          job_class = dependency["job_class"]
          job_id = dependency["job_id"]
          return unless job_class && job_id

          workflow_id = "#{WorkflowIdBuilder::DEFAULT_PREFIX}:#{job_class}:#{job_id}"
          WorkflowIdBuilder.validate!(workflow_id)
          {
            workflow_id: workflow_id,
            run_id: nil
          }
        end

        def workflow_search_query(dependency)
          filters = ["ajJobId='#{safe_query_value(dependency.fetch('job_id'))}'"]
          job_class = dependency["job_class"]
          filters.unshift("ajClass='#{safe_query_value(job_class)}'") if job_class
          filters.join(" AND ")
        end

        def safe_query_value(value)
          string_value = value.to_s
          return string_value if string_value.match?(SAFE_QUERY_VALUE_PATTERN)

          raise ArgumentError,
                "dependency query values may only contain letters, numbers, underscore, hyphen, period, and colon"
        end

        def describe_workflow(workflow_reference)
          client.workflow_handle(
            workflow_reference.fetch(:workflow_id),
            run_id: workflow_reference[:run_id]
          ).describe
        end

        def describe_search_attribute_workflow(dependency)
          return unless dependency["workflow_id"] && dependency["job_id"]

          fallback_dependency = dependency.dup
          fallback_dependency.delete("workflow_id")
          workflow_reference = search_workflow_reference(fallback_dependency)
          return unless workflow_reference

          describe_workflow(workflow_reference)
        rescue StandardError => e
          return nil if rpc_not_found?(e) || rpc_invalid_argument?(e)

          raise
        end

        def status_payload(dependency, state, workflow_id: nil, run_id: nil)
          {
            "job_id" => dependency["job_id"],
            "job_class" => dependency["job_class"],
            "workflow_id" => workflow_id || dependency["workflow_id"],
            "run_id" => run_id,
            "state" => state
          }.compact
        end

        def client
          ActiveJob::Temporal.client
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
