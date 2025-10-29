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
      # Deterministic orchestration workflow for ActiveJob execution.
      #
      # This workflow serves as the durable scheduling and orchestration layer for ActiveJob.
      # It handles delayed execution (via `Workflow.sleep`) and invokes the activity that
      # executes the actual job logic.
      #
      # @note Workflow Determinism
      #   This workflow MUST remain deterministic. It contains no I/O operations,
      #   no random number generation, no system time calls (only `Workflow.now`),
      #   and no direct method calls to external services. All side effects occur
      #   in the activity layer.
      #
      # @example Workflow execution flow
      #   1. Extract scheduled_at timestamp from payload
      #   2. If scheduled_at is in the future, sleep until that time
      #   3. Execute AjRunnerActivity with the payload and retry policy
      #   4. Return activity result
      class AjWorkflow < Temporalio::Workflow::Definition
        # Executes the workflow: optionally sleeps until scheduled time, then runs the activity.
        #
        # @param payload [Hash] Job payload containing execution metadata
        # @option payload [String] :job_class Fully-qualified job class name
        # @option payload [String] :job_id Unique job identifier
        # @option payload [String] :queue_name Target queue name
        # @option payload [Array] :arguments Serialized job arguments
        # @option payload [String] :scheduled_at ISO8601 timestamp for delayed execution (optional)
        # @option payload [Integer] :executions Current execution count (default: 0)
        # @option payload [Hash] :exception_executions Exception execution counts (default: {})
        #
        # @return [Object, nil] Result from the activity execution
        #
        # @example Immediate execution
        #   execute({ job_class: "MyJob", job_id: "123", arguments: ["arg1"] })
        #
        # @example Scheduled execution
        #   execute({
        #     job_class: "MyJob",
        #     job_id: "123",
        #     scheduled_at: "2025-10-29T12:00:00Z",
        #     arguments: []
        #   })
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
