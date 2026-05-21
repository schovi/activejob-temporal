# frozen_string_literal: true

require "time"
require "active_support/core_ext/hash/keys"
require "temporalio/error"
require "temporalio/retry_policy"
require "temporalio/workflow"

require_relative "../activities/rate_limit_activity"
require_relative "dead_letter_support"
require_relative "workflow_interactions"

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
      #   in the activity layer. Temporal replays workflow code on every restart,
      #   so non-deterministic changes will cause workflow execution errors.
      #
      # @note Non-Blocking Sleep
      #   The `Workflow.sleep` method uses Temporal's durable timer mechanism. This means
      #   scheduled jobs do not consume worker resources while waiting. The workflow is
      #   persisted, and Temporal wakes it up at the scheduled time.
      #
      # @example Workflow execution flow
      #   1. Extract scheduled_at timestamp from payload
      #   2. If scheduled_at is in the future, sleep until that time (non-blocking)
      #   3. Execute AjRunnerActivity with the payload and retry policy
      #   4. Return activity result
      #
      # @example Replay behavior
      #   # If a worker crashes during step 3, Temporal will replay the workflow:
      #   # - Step 1: Re-reads scheduled_at (deterministic)
      #   # - Step 2: Skips sleep (already elapsed, replayed from history)
      #   # - Step 3: Continues from last checkpoint
      #
      # @see https://docs.temporal.io/workflows#deterministic-constraints Temporal Determinism Guide
      # @see https://docs.temporal.io/workflows#timers Temporal Durable Timers
      class AjWorkflow < Temporalio::Workflow::Definition
        include DeadLetterSupport
        include WorkflowInteractions

        DEFAULT_START_TO_CLOSE_TIMEOUT = 900.0
        RATE_LIMIT_ACTIVITY_TIMEOUT = 30.0
        RATE_LIMIT_RETRY_POLICY = Temporalio::RetryPolicy.new(max_attempts: 1)

        workflow_signal dynamic: true
        def handle_dynamic_signal(signal_name, *args)
          handler_name = normalize_handler_name!(signal_name, "signal")

          case handler_name
          when "pause" then pause_workflow(args)
          when "resume" then resume_workflow(args)
          else dispatch_custom_signal(handler_name, args)
          end
        end

        workflow_query dynamic: true
        def handle_dynamic_query(query_name, *args)
          handler_name = normalize_handler_name!(query_name, "query")

          case handler_name
          when "state" then deep_copy(workflow_state)
          when "paused" then workflow_state["paused"]
          when "pause_reason" then workflow_state["pause_reason"]
          when "phase" then workflow_state["phase"]
          when "signals" then deep_copy(workflow_state["signals"])
          else dispatch_custom_query(handler_name, args)
          end
        end

        # Executes the workflow: optionally sleeps until scheduled time, then runs the activity.
        #
        # @param payload [Hash] Job payload containing execution metadata
        # @option payload [String] :job_class Fully-qualified job class name (required)
        # @option payload [String] :job_id Unique job identifier (required)
        # @option payload [String] :queue_name Target queue name (required)
        # @option payload [Array] :arguments Serialized job arguments (required)
        # @option payload [Hash] :default_activity_options Global activity timeout defaults (required)
        # @option payload [Hash] :retry_policy Retry policy for activity execution (required)
        # @option payload [Hash] :temporal_options Per-job timeout configuration (optional)
        # @option payload [String] :scheduled_at ISO8601 timestamp for delayed execution (optional)
        # @option payload [Integer] :executions Current execution count (default: 0)
        # @option payload [Hash] :exception_executions Exception execution counts (default: {})
        #
        # @return [Object, nil] Result from the activity execution
        #
        # @raise [Temporalio::Error::ActivityError] if activity execution fails (propagates from activity)
        # @raise [Temporalio::Error::TimeoutError] if activity exceeds start_to_close_timeout
        #
        # @note Durable Timers
        #   If scheduled_at is in the future, the workflow creates a durable timer.
        #   The timer persists across worker restarts and does not block worker threads.
        #
        # @example Immediate execution
        #   execute({ job_class: "MyJob", job_id: "123", arguments: ["arg1"] })
        #
        # @example Scheduled execution (non-blocking sleep)
        #   execute({
        #     job_class: "MyJob",
        #     job_id: "123",
        #     scheduled_at: "2025-10-31T12:00:00Z",
        #     arguments: []
        #   })
        #   # Workflow sleeps until scheduled time without consuming worker resources
        #
        # @example Replay behavior on worker restart
        #   # Initial execution: Workflow sleeps for 1 hour
        #   # Worker crashes after 30 minutes
        #   # Workflow is replayed: Sleep is skipped (already elapsed), activity executes immediately
        #
        # @note Durable Timer Guarantees
        #   Temporal's durable timers persist across worker restarts and cluster outages.
        #   Even if all workers are down, the scheduled job will execute once workers
        #   are back online. The timer is stored in Temporal's event history, making it
        #   highly reliable for long-term scheduling.
        #
        # @see Activities::AjRunnerActivity#execute
        def execute(payload)
          configure_workflow_state(payload)
          configure_workflow_interactions(payload)

          scheduled_time = extract_scheduled_time(payload)
          workflow_state["phase"] = "scheduled" if scheduled_time
          sleep_until(scheduled_time) if scheduled_time
          wait_while_paused

          wait_for_rate_limit(payload)
          wait_while_paused

          workflow_state["phase"] = "running_activity"
          result = Temporalio::Workflow.execute_activity(
            ActiveJob::Temporal::Activities::AjRunnerActivity,
            payload,
            **activity_options(payload)
          )
          workflow_state["phase"] = "completed"
          result
        rescue Temporalio::Error::ActivityError => e
          workflow_state["phase"] = "failed"
          start_dead_letter_workflow(payload, e) if dead_letterable_failure?(payload, e)
          raise
        end

        private

        # Extracts scheduled execution time from payload.
        # @api private
        def extract_scheduled_time(payload)
          timestamp = payload[:scheduled_at] || payload["scheduled_at"]
          return unless timestamp

          Time.iso8601(timestamp)
        end

        # Sleeps until target time using Temporal's durable timer.
        # @api private
        def sleep_until(target_time)
          now = Temporalio::Workflow.now
          delay = target_time - now
          return unless delay.positive?

          Temporalio::Workflow.sleep(delay)
        end

        def wait_for_rate_limit(payload)
          return unless rate_limits?(payload)

          workflow_state["phase"] = "waiting_rate_limit"
          loop do
            wait_while_paused
            wait_time = Temporalio::Workflow.execute_activity(
              ActiveJob::Temporal::Activities::RateLimitActivity,
              payload,
              schedule_to_close_timeout: RATE_LIMIT_ACTIVITY_TIMEOUT,
              start_to_close_timeout: RATE_LIMIT_ACTIVITY_TIMEOUT,
              retry_policy: RATE_LIMIT_RETRY_POLICY
            ).to_f
            break unless wait_time.positive?

            Temporalio::Workflow.sleep(wait_time)
          end
        end

        def rate_limits?(payload)
          Array(payload[:rate_limits] || payload["rate_limits"]).any?
        end

        # Builds activity execution options with timeout configuration and retry policy.
        #
        # Merges timeout options from deterministic payload values only.
        #
        # @api private
        def activity_options(payload)
          options = default_activity_options(payload)

          temporal_opts = payload[:temporal_options] || payload["temporal_options"]
          options.merge!(temporal_opts.symbolize_keys) if temporal_opts

          retry_policy_hash = payload[:retry_policy] || payload["retry_policy"]
          options[:retry_policy] = build_retry_policy(retry_policy_hash) if retry_policy_hash

          options
        end

        # Builds activity timeout defaults from workflow input.
        # @api private
        def default_activity_options(payload)
          options = payload[:default_activity_options] || payload["default_activity_options"]
          return options.symbolize_keys if options

          { start_to_close_timeout: DEFAULT_START_TO_CLOSE_TIMEOUT }
        end

        # Builds Temporalio::RetryPolicy from hash.
        # @api private
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
