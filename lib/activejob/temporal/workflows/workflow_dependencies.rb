# frozen_string_literal: true

require "temporalio/error"

require_relative "../activities/dependency_status_activity"

module ActiveJob
  module Temporal
    module Workflows
      module WorkflowDependencies
        DEPENDENCY_CHECK_ACTIVITY_TIMEOUT = 30.0
        DEPENDENCY_CHECK_RETRY_POLICY = Temporalio::RetryPolicy.new(max_attempts: 1)
        DEPENDENCY_WAIT_INTERVAL = 10.0
        DEPENDENCY_NOT_FOUND_MAX_CHECKS = 6
        COMPLETED_DEPENDENCY_STATES = %w[completed].freeze
        FAILED_DEPENDENCY_STATES = %w[failed canceled terminated timed_out unknown].freeze
        NOT_FOUND_DEPENDENCY_STATES = %w[not_found].freeze

        private

        def wait_for_dependencies(payload)
          dependencies = dependency_metadata(payload)
          return if dependencies.empty?

          workflow_state["phase"] = "waiting_dependencies"
          not_found_counts = Hash.new(0)
          loop do
            wait_while_paused
            statuses = check_dependency_statuses(dependencies)
            expired_not_found_statuses = expired_not_found_statuses(statuses, not_found_counts)
            failed_statuses = failed_dependency_statuses(statuses) + expired_not_found_statuses
            fail_for_dependencies!(failed_statuses) if fail_on_dependency_failure?(payload) && failed_statuses.any?
            break if dependencies_satisfied?(statuses, expired_not_found_statuses)

            Temporalio::Workflow.sleep(DEPENDENCY_WAIT_INTERVAL)
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
          status["state"] || status[:state]
        end

        def dependency_status_key(status)
          job_class = status["job_class"] || status[:job_class]
          job_id = status["job_id"] || status[:job_id]
          return "#{job_class}:#{job_id}" if job_class && job_id
          return job_id if job_id

          status["workflow_id"] || status[:workflow_id] || status.hash
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
      end
    end
  end
end
