# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Workflows
      module WorkflowVersioning
        PATCHES = {
          continue_as_new: "activejob-temporal.continue-as-new-v1",
          local_activity_helpers: "activejob-temporal.local-activity-helpers-v1",
          workflow_state: "activejob-temporal.workflow-state-v1"
        }.freeze

        private

        def workflow_patch_enabled?(patch_name)
          Temporalio::Workflow.patched(PATCHES.fetch(patch_name))
        end
      end
    end
  end
end
