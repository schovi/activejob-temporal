# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Workflows
      module WorkflowContinueAsNew
        private

        def continue_as_new_if_needed(payload)
          return unless workflow_patch_enabled?(:continue_as_new)

          continue_as_new_options = payload[:continue_as_new] || payload["continue_as_new"]
          return unless continue_as_new_options
          return unless continue_as_new_threshold_reached?(continue_as_new_options)

          wait_for_continue_as_new_handlers
          workflow_state["phase"] = "continuing_as_new"
          raise Temporalio::Workflow::ContinueAsNewError.new(
            continue_as_new_payload(payload),
            search_attributes: Temporalio::Workflow.search_attributes
          )
        end

        def continue_as_new_threshold_reached?(continue_as_new_options)
          threshold = continue_as_new_options[:history_event_threshold] ||
                      continue_as_new_options["history_event_threshold"]
          return false unless threshold.to_i.positive?

          Temporalio::Workflow.current_history_length >= threshold.to_i
        end

        def continue_as_new_payload(payload)
          deep_copy(payload).merge("workflow_state" => deep_copy(workflow_state))
        end

        def wait_for_continue_as_new_handlers
          return if Temporalio::Workflow.all_handlers_finished?

          Temporalio::Workflow.wait_condition { Temporalio::Workflow.all_handlers_finished? }
        end
      end
    end
  end
end
