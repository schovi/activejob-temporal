# frozen_string_literal: true

require "temporalio/activity"

module ActiveJob
  module Temporal
    module Activities
      # Activity wrapper around user-configured rate limiter I/O.
      class RateLimitActivity < Temporalio::Activity::Definition
        def execute(payload)
          rate_limits = payload[:rate_limits] || payload["rate_limits"]
          return 0.0 if Array(rate_limits).empty?

          limiter = ActiveJob::Temporal.config.rate_limiter
          raise ConfigurationError, "rate_limiter is required when rate limits are configured" unless limiter

          normalize_wait_time(call_limiter(limiter, rate_limits))
        end

        private

        def call_limiter(limiter, rate_limits)
          return limiter.wait_time_for(rate_limits) if limiter.respond_to?(:wait_time_for)
          return limiter.call(rate_limits) if limiter.respond_to?(:call)

          raise ConfigurationError, "rate_limiter must respond to #wait_time_for or #call"
        end

        def normalize_wait_time(value)
          wait_time = Float(value)
          raise ArgumentError, "rate limiter wait time must be finite" unless wait_time.finite?
          raise ArgumentError, "rate limiter wait time must not be negative" if wait_time.negative?

          wait_time
        rescue TypeError
          raise ArgumentError, "rate limiter wait time must be numeric"
        end
      end
    end
  end
end
