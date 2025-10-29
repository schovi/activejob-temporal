# frozen_string_literal: true

require "time"

unless defined?(Temporalio::Workflow::Definition)
  module Temporalio
    module Workflow
      Definition = Class.new
    end
  end
end

unless defined?(Temporalio::RetryPolicy)
  module Temporalio
    RetryPolicy = Data.define(
      :initial_interval,
      :backoff_coefficient,
      :max_interval,
      :max_attempts,
      :non_retryable_error_types
    )
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
            ActiveJob::Temporal::Activities::AjRunnerActivity,
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

          # Look up job class and build retry policy
          job_class_name = payload[:job_class] || payload["job_class"]
          if job_class_name
            job_class = Object.const_get(job_class_name)
            retry_policy_hash = ActiveJob::Temporal::RetryMapper.for(job_class)
            options[:retry_policy] = build_retry_policy(retry_policy_hash)
          end

          options
        end

        def build_retry_policy(hash)
          # RetryMapper returns maximum_attempts, but Temporalio::RetryPolicy expects max_attempts
          max_attempts_value = hash[:maximum_attempts] || hash["maximum_attempts"]

          Temporalio::RetryPolicy.new(
            initial_interval: hash[:initial_interval] || hash["initial_interval"],
            backoff_coefficient: hash[:backoff_coefficient] || hash["backoff_coefficient"],
            max_interval: hash[:max_interval] || hash["max_interval"],
            max_attempts: max_attempts_value,
            non_retryable_error_types: hash[:non_retryable_error_types] || hash["non_retryable_error_types"]
          )
        end
      end
    end
  end
end
