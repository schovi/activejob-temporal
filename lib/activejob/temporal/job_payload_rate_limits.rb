# frozen_string_literal: true

require_relative "rate_limit_options"

module ActiveJob
  module Temporal
    module JobPayloadRateLimits
      private

      def apply_rate_limits(payload, job)
        rate_limits = rate_limits_for(job.class)
        payload[:rate_limits] = rate_limits if rate_limits.any?
      end

      def rate_limits_for(job_class)
        rate_limits = [
          configured_global_rate_limit,
          configured_job_rate_limit(job_class)
        ].compact
        validate_rate_limiter!(rate_limits)
        rate_limits
      end

      def configured_global_rate_limit
        return unless @config.respond_to?(:global_rate_limit) && @config.global_rate_limit

        normalize_rate_limit(@config.global_rate_limit, default_key: "activejob-temporal:global")
      end

      def configured_job_rate_limit(job_class)
        return unless job_class.respond_to?(:rate_limit)

        rate_limit = job_class.rate_limit
        return if rate_limit.empty?

        normalize_rate_limit(rate_limit, default_key: "activejob-temporal:job:#{job_class.name}")
      end

      def normalize_rate_limit(rate_limit, default_key:)
        normalized = RateLimitOptions.normalize_hash(rate_limit)
        normalized[:key] ||= default_key
        normalized
      end

      def validate_rate_limiter!(rate_limits)
        return if rate_limits.empty?
        return if @config.respond_to?(:rate_limiter) && @config.rate_limiter

        raise ConfigurationError, "rate_limiter is required when rate limits are configured"
      end
    end
  end
end
