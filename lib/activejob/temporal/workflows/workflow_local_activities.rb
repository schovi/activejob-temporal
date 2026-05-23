# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Workflows
      module WorkflowLocalActivities
        private

        def execute_helper_activity(payload, helper_name, activity, *, **)
          if local_activity_helper?(payload, helper_name)
            Temporalio::Workflow.execute_local_activity(activity, *, **)
          else
            Temporalio::Workflow.execute_activity(activity, *, **)
          end
        end

        def local_activity_helper?(payload, helper_name)
          return false unless workflow_patch_enabled?(:local_activity_helpers)

          local_activity_helper_names(payload).include?(helper_name.to_s)
        end

        def local_activity_helper_names(payload)
          Array(payload[:local_activity_helpers] || payload["local_activity_helpers"]).map(&:to_s)
        end
      end
    end
  end
end
