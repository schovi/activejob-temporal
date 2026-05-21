# frozen_string_literal: true

require "active_job"
require "active_support/concern"
require "active_support/core_ext/numeric/time"

module ActiveJob
  module Temporal
    # Provides per-job rate limit metadata via the +rate_limit+ class method.
    module RateLimitOptions
      extend ActiveSupport::Concern

      PERIOD_SECONDS = {
        second: 1.0,
        minute: 60.0,
        hour: 3600.0
      }.freeze

      def self.normalize(limit, per:, key: nil)
        normalized_limit = normalize_limit(limit)
        normalized_interval = normalize_interval(per)
        normalized = { limit: normalized_limit, interval: normalized_interval }
        normalized[:key] = normalize_key(key) if key
        normalized
      end

      def self.normalize_hash(value)
        raise ArgumentError, "rate limit must be a Hash" unless value.is_a?(Hash)

        limit = value[:limit] || value["limit"]
        interval = value[:interval] || value["interval"]
        per = value[:per] || value["per"] || interval
        key = value[:key] || value["key"]

        normalize(limit, per: per, key: key)
      end

      def self.normalize_limit(limit)
        raise ArgumentError, "rate limit must be a positive integer" unless limit.is_a?(Integer) && limit.positive?

        limit
      end
      private_class_method :normalize_limit

      def self.normalize_interval(value)
        interval = case value
                   when Symbol
                     PERIOD_SECONDS.fetch(value) { raise ArgumentError, "unsupported rate limit period: #{value}" }
                   when ActiveSupport::Duration, Numeric
                     value.to_f
                   else
                     raise ArgumentError, "rate limit period must be a Symbol, Numeric, or ActiveSupport::Duration"
                   end

        unless interval.finite? && interval.positive?
          raise ArgumentError, "rate limit period must be finite and positive"
        end

        interval
      end
      private_class_method :normalize_interval

      def self.normalize_key(key)
        normalized_key = key.to_s.strip
        raise ArgumentError, "rate limit key must be present" if normalized_key.empty?

        normalized_key
      end
      private_class_method :normalize_key

      class_methods do
        def rate_limit(limit = nil, per: nil, key: nil)
          if limit
            raise ArgumentError, "rate limit period is required" if per.nil?

            @rate_limit_options = RateLimitOptions.normalize(limit, per: per, key: key)
          end

          @rate_limit_options || inherited_rate_limit_options || {}
        end

        private

        def inherited_rate_limit_options
          return unless superclass.respond_to?(:rate_limit)

          superclass.rate_limit
        end
      end
    end
  end
end

ActiveJob::Base.include(ActiveJob::Temporal::RateLimitOptions) if defined?(ActiveJob::Base)
