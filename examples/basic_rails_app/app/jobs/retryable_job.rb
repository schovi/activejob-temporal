# frozen_string_literal: true

class RetryableJobError < StandardError; end

class RetryableJob < ApplicationJob
  queue_as :default

  retry_on RetryableJobError, wait: 5.seconds, attempts: 5

  def perform(message, should_fail: false, attempt_key: job_id)
    Rails.logger.info "RetryableJob executed with message: #{message}"

    attempt = record_attempt(attempt_key)
    Rails.logger.info "RetryableJob attempt: #{attempt}"

    if should_fail && attempt < 3
      Rails.logger.warn "RetryableJob: Simulating transient failure (attempt #{attempt})"
      raise RetryableJobError, "Transient error - will retry"
    end

    sleep 1
    Rails.cache.delete(attempt_cache_key(attempt_key)) if should_fail
    Rails.logger.info "RetryableJob completed successfully"
  end

  private

  def record_attempt(attempt_key)
    cache_key = attempt_cache_key(attempt_key)
    attempt = Rails.cache.fetch(cache_key) { 0 } + 1
    Rails.cache.write(cache_key, attempt, expires_in: 10.minutes)
    attempt
  end

  def attempt_cache_key(attempt_key)
    "retryable_job_attempts/#{attempt_key}"
  end
end
