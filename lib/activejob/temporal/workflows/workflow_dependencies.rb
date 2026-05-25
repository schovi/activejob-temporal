# frozen_string_literal: true

require "time"
require "timeout"
require "temporalio/error"

require_relative "../activities/dependency_status_activity"

module ActiveJob
  module Temporal
    module Workflows
      module WorkflowDependencies
        DEPENDENCY_CHECK_ACTIVITY_TIMEOUT = 30.0
        DEPENDENCY_CHECK_RETRY_POLICY = Temporalio::RetryPolicy.new(max_attempts: 1)
        DEPENDENCY_WAIT_INTERVAL = 10.0
        DEPENDENCY_WAIT_TIMEOUT = 86_400.0
        DEPENDENCY_WAIT_MAX_INTERVAL = 60.0
        DEPENDENCY_WAIT_BACKOFF = 2.0
        DEPENDENCY_NOT_FOUND_MAX_CHECKS = 6
        COMPLETED_DEPENDENCY_STATES = %w[completed continued_as_new].freeze
        FAILED_DEPENDENCY_STATES = %w[failed canceled terminated timed_out unknown].freeze
        NOT_FOUND_DEPENDENCY_STATES = %w[not_found].freeze

        private

        def wait_for_dependencies(payload)
          dependencies = dependency_metadata(payload)
          return if dependencies.empty?

          workflow_state["phase"] = "waiting_dependencies"
          wait_options = dependency_wait_options(payload)
          deadline = dependency_wait_deadline(wait_options)
          begin
            with_dependency_wait_timeout(wait_options, deadline) do
              wait_for_dependency_statuses(payload, dependencies, wait_options)
            end
          rescue Timeout::Error
            timed_out_statuses = dependency_timeout_statuses(dependencies)
            if fail_on_dependency_failure?(payload)
              fail_for_dependencies!(timed_out_statuses)
            else
              workflow_state.delete("dependency_wait")
            end
          end
        end

        def dependency_metadata(payload)
          Array(payload[:dependencies] || payload["dependencies"])
        end

        def check_dependency_statuses(dependencies)
          Temporalio::Workflow.execute_activity(
            ActiveJob::Temporal::Activities::DependencyStatusActivity,
            dependencies,
            schedule_to_close_timeout: DEPENDENCY_CHECK_ACTIVITY_TIMEOUT,
            start_to_close_timeout: DEPENDENCY_CHECK_ACTIVITY_TIMEOUT,
            retry_policy: DEPENDENCY_CHECK_RETRY_POLICY
          )
        end

        def wait_for_dependency_statuses(payload, dependencies, wait_options)
          not_found_counts = dependency_wait_not_found_counts
          wait_interval = dependency_wait_current_interval(wait_options)
          loop do
            wait_while_paused
            statuses = check_dependency_statuses(dependencies)
            expired_not_found_statuses = expired_not_found_statuses(statuses, not_found_counts)
            failed_statuses = failed_dependency_statuses(statuses) + expired_not_found_statuses
            fail_for_dependencies!(failed_statuses) if fail_on_dependency_failure?(payload) && failed_statuses.any?
            break if dependencies_satisfied?(statuses, expired_not_found_statuses)

            persist_dependency_wait_state(not_found_counts, wait_interval)
            continue_as_new_if_needed(payload)
            Temporalio::Workflow.sleep(wait_interval)
            wait_interval = next_dependency_wait_interval(wait_interval, wait_options)
          end
          workflow_state.delete("dependency_wait")
        end

        def with_dependency_wait_timeout(wait_options, deadline, &)
          remaining_timeout = dependency_wait_remaining_timeout(deadline)
          raise Timeout::Error, "dependency wait timed out" unless remaining_timeout.positive?

          Temporalio::Workflow.timeout(
            remaining_timeout,
            Timeout::Error,
            "dependency wait timed out after #{wait_options[:timeout]} seconds",
            summary: "Dependency wait timeout",
            &
          )
        end

        def dependency_wait_options(payload)
          configured_options = payload[:dependency_wait] || payload["dependency_wait"] || {}
          initial_interval = positive_float_option(configured_options, :initial_interval, DEPENDENCY_WAIT_INTERVAL)
          max_interval = positive_float_option(configured_options, :max_interval, DEPENDENCY_WAIT_MAX_INTERVAL)
          {
            timeout: positive_float_option(configured_options, :timeout, DEPENDENCY_WAIT_TIMEOUT),
            initial_interval: initial_interval,
            max_interval: [max_interval, initial_interval].max,
            backoff: backoff_option(configured_options)
          }
        end

        def positive_float_option(options, key, default)
          value = options[key] || options[key.to_s]
          return default unless value

          number = Float(value)
          number.positive? ? number : default
        rescue ArgumentError, TypeError
          default
        end

        def backoff_option(options)
          value = options[:backoff] || options["backoff"]
          return DEPENDENCY_WAIT_BACKOFF unless value

          backoff = Float(value)
          backoff >= 1.0 ? backoff : DEPENDENCY_WAIT_BACKOFF
        rescue ArgumentError, TypeError
          DEPENDENCY_WAIT_BACKOFF
        end

        def dependency_wait_not_found_counts
          Hash.new(0).merge(dependency_wait_state["not_found_counts"] || {})
        end

        def dependency_wait_current_interval(wait_options)
          current_interval = dependency_wait_state["current_interval"]
          return wait_options[:initial_interval] unless current_interval

          interval = Float(current_interval)
          interval.positive? ? interval : wait_options[:initial_interval]
        rescue ArgumentError, TypeError
          wait_options[:initial_interval]
        end

        def dependency_wait_state
          workflow_state["dependency_wait"] ||= {}
        end

        def dependency_wait_deadline(wait_options)
          deadline_at = dependency_wait_state["deadline_at"]
          return Time.iso8601(deadline_at) if deadline_at

          persist_dependency_wait_deadline(wait_options)
        rescue ArgumentError, TypeError
          persist_dependency_wait_deadline(wait_options)
        end

        def persist_dependency_wait_deadline(wait_options)
          deadline = Temporalio::Workflow.now + wait_options[:timeout]
          dependency_wait_state["deadline_at"] = deadline.iso8601
          deadline
        end

        def dependency_wait_remaining_timeout(deadline)
          deadline - Temporalio::Workflow.now
        end

        def persist_dependency_wait_state(not_found_counts, wait_interval)
          dependency_wait_state["not_found_counts"] = not_found_counts
          dependency_wait_state["current_interval"] = wait_interval
        end

        def next_dependency_wait_interval(wait_interval, wait_options)
          [wait_interval * wait_options[:backoff], wait_options[:max_interval]].min
        end

        def dependencies_satisfied?(statuses, expired_not_found_statuses)
          expired_not_found_keys = expired_not_found_statuses.map { |status| dependency_status_key(status) }
          statuses.all? do |status|
            state = dependency_state(status)
            COMPLETED_DEPENDENCY_STATES.include?(state) ||
              FAILED_DEPENDENCY_STATES.include?(state) ||
              expired_not_found_keys.include?(dependency_status_key(status))
          end
        end

        def expired_not_found_statuses(statuses, not_found_counts)
          statuses.each_with_object([]) do |status, expired_statuses|
            key = dependency_status_key(status)
            if NOT_FOUND_DEPENDENCY_STATES.include?(dependency_state(status))
              not_found_counts[key] += 1
              expired_statuses << status if not_found_counts[key] >= DEPENDENCY_NOT_FOUND_MAX_CHECKS
            else
              not_found_counts.delete(key)
            end
          end
        end

        def failed_dependency_statuses(statuses)
          statuses.select do |status|
            FAILED_DEPENDENCY_STATES.include?(dependency_state(status))
          end
        end

        def dependency_state(status)
          status_value(status, :state)
        end

        def dependency_status_key(status)
          job_class = status_value(status, :job_class)
          job_id = status_value(status, :job_id)
          workflow_id = status_value(status, :workflow_id)
          run_id = status_value(status, :run_id)
          return "#{job_class}:#{job_id}" if job_class && job_id
          return job_id if job_id
          return [workflow_id, run_id].compact.join(":") if workflow_id

          status.hash
        end

        def status_value(status, key)
          status[key.to_s] || status[key]
        end

        def fail_on_dependency_failure?(payload)
          policy = payload[:dependency_failure_policy] || payload["dependency_failure_policy"] || "fail"
          policy.to_s == "fail"
        end

        def fail_for_dependencies!(statuses)
          descriptions = statuses.map do |status|
            identifier = status["workflow_id"] || status[:workflow_id] || status["job_id"] || status[:job_id]
            state = status["state"] || status[:state]
            "#{identifier}: #{state}"
          end

          raise Temporalio::Error::ApplicationError.new(
            "Job dependency failed: #{descriptions.join(', ')}",
            type: "ActiveJob::Temporal::DependencyFailed",
            non_retryable: true
          )
        end

        def dependency_timeout_statuses(dependencies)
          dependencies.map do |dependency|
            dependency.each_with_object({ "state" => "timed_out" }) do |(key, value), status|
              status[key.to_s] = value
            end
          end
        end
      end
    end
  end
end
