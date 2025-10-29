# frozen_string_literal: true

# Custom error for demonstrating retry behavior
class RetryableJobError < StandardError; end

# RetryableJob demonstrates automatic retry behavior with exponential backoff
# Uses retry_on to automatically retry failed jobs
class RetryableJob < ApplicationJob
  queue_as :default

  # Retry up to 5 times with 30 seconds initial delay (exponential backoff)
  retry_on RetryableJobError, wait: 30.seconds, attempts: 5

  def perform(message, should_fail: false)
    Rails.logger.info "RetryableJob executed with message: #{message}"
    Rails.logger.info "Execution count: #{executions}"

    if should_fail && executions < 3
      Rails.logger.warn "RetryableJob: Simulating transient failure (attempt #{executions})"
      raise RetryableJobError, "Transient error - will retry"
    end

    # Simulate some work
    sleep 1
    Rails.logger.info "RetryableJob completed successfully"
  end
end
