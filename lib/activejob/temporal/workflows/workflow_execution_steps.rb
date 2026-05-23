# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Workflows
      module WorkflowExecutionSteps
        private

        def execute_workflow_steps(payload, &)
          continue_as_new_if_needed(payload)
          wait_until_scheduled(payload)
          continue_as_new_if_needed(payload)
          wait_for_dependencies(payload)
          continue_as_new_if_needed(payload)
          result = execute_activity_payload(payload)
          result = execute_child_workflow_sequence(payload, result)
          execute_chain_sequence(payload, result, &)
        end
      end
    end
  end
end
