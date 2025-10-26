# frozen_string_literal: true

require "time"

unless defined?(Temporalio::Workflow::Definition)
  module Temporalio
    module Workflow
      Definition = Class.new
    end
  end
end

module ActiveJob
  module Temporal
    module Workflows
      # AjWorkflow is the deterministic orchestration layer that optionally delays
      # execution until the scheduled time and then hands control to AjRunnerActivity.
      class AjWorkflow < Temporalio::Workflow::Definition
        def execute(payload)
          scheduled_time = extract_scheduled_time(payload)
          sleep_until(scheduled_time) if scheduled_time

          Temporalio::Workflow.execute_activity(
            AjRunnerActivity,
            payload,
            **activity_options(payload)
          )
        end

        private

        def extract_scheduled_time(payload)
          timestamp = payload[:scheduled_at] || payload["scheduled_at"]
          return unless timestamp

          Time.iso8601(timestamp)
        end

        def sleep_until(target_time)
          now = Temporalio::Workflow.now
          delay = target_time - now
          return unless delay.positive?

          Temporalio::Workflow.sleep(delay)
        end

        def activity_options(payload)
          options = {
            start_to_close_timeout: ActiveJob::Temporal.config.default_activity_timeout
          }
          retry_policy = payload[:retry_policy] || payload["retry_policy"]
          options[:retry] = retry_policy if retry_policy
          options
        end
      end
    end
  end
end
