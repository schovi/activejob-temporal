# frozen_string_literal: true

require "time"
require "temporalio/search_attributes"
require "temporalio/workflow"

require_relative "../search_attributes"

module ActiveJob
  module Temporal
    module Workflows
      module WorkflowChildWorkflows
        private

        def execute_child_workflow_sequence(payload, parent_result)
          child_payloads = child_workflow_payloads(payload)
          return parent_result if child_payloads.empty?

          workflow_state["phase"] = "running_child_workflows"
          handles = start_child_job_workflows(child_payloads, parent_result)
          child_results = collect_child_workflow_results(child_payloads, handles)

          {
            "parent_result" => parent_result,
            "child_results" => child_results
          }
        ensure
          workflow_state.delete("child_index")
        end

        def child_workflow_payloads(payload)
          Array(payload[:child_workflows] || payload["child_workflows"])
        end

        def start_child_job_workflows(child_payloads, parent_result)
          child_payloads.each_with_index.map do |child_payload, index|
            workflow_state["child_index"] = index + 1
            start_child_job_workflow(child_payload, parent_result)
          end
        end

        def collect_child_workflow_results(child_payloads, handles)
          handles.each_with_index.map do |handle, index|
            workflow_state["child_index"] = index + 1
            child_workflow_result(child_payloads.fetch(index), handle.result)
          end
        end

        def start_child_job_workflow(child_payload, parent_result)
          workflow_payload = child_payload_with_parent_result(child_payload, parent_result)
          Temporalio::Workflow.start_child_workflow(
            ActiveJob::Temporal::Workflows::AjWorkflow,
            workflow_payload,
            **child_workflow_options(workflow_payload)
          )
        end

        def child_workflow_options(child_payload)
          task_queue = payload_value(child_payload, :workflow_task_queue) ||
                       payload_value(child_payload, :activity_task_queue)
          options = {
            id: payload_value(child_payload, :workflow_id),
            task_queue: task_queue,
            parent_close_policy: Temporalio::Workflow::ParentClosePolicy::REQUEST_CANCEL,
            cancellation_type: Temporalio::Workflow::ChildWorkflowCancellationType::WAIT_CANCELLATION_COMPLETED
          }.compact
          search_attributes = child_search_attributes(payload_value(child_payload, :search_attributes))
          options[:search_attributes] = search_attributes if search_attributes
          options
        end

        def child_payload_with_parent_result(child_payload, parent_result)
          key = child_payload.key?(:arguments) ? :arguments : "arguments"
          child_payload.merge(key => [parent_result])
        end

        def child_workflow_result(child_payload, result)
          {
            "job_class" => payload_value(child_payload, :job_class),
            "job_id" => payload_value(child_payload, :job_id),
            "workflow_id" => payload_value(child_payload, :workflow_id),
            "result" => result
          }
        end

        def child_search_attributes(metadata)
          return unless metadata

          attributes = Temporalio::SearchAttributes.new
          attributes[search_attribute_key(:aj_class)] = payload_value(metadata, :job_class)
          attributes[search_attribute_key(:aj_queue)] = payload_value(metadata, :queue_name) || "default"
          attributes[search_attribute_key(:aj_job_id)] = payload_value(metadata, :job_id)
          attributes[search_attribute_key(:aj_enqueued_at)] = Time.iso8601(payload_value(metadata, :enqueued_at))

          tags = Array(payload_value(metadata, :tags))
          attributes[search_attribute_key(:aj_tags)] = tags if tags.any?
          attributes
        end

        def search_attribute_key(key)
          name, type = ActiveJob::Temporal::SearchAttributes::SEARCH_ATTRIBUTE_KEY_DEFINITIONS.fetch(key)
          type_constant = Temporalio::SearchAttributes::IndexedValueType.const_get(type)
          Temporalio::SearchAttributes::Key.new(name, type_constant)
        end
      end
    end
  end
end
