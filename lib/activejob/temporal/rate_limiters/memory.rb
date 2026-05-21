# frozen_string_literal: true

require_relative "../rate_limit_options"

module ActiveJob
  module Temporal
    module RateLimiters
      # Process-local sliding-window limiter for development, tests, and single-worker setups.
      class Memory
        def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @clock = clock
          @timestamps_by_bucket = Hash.new { |timestamps, bucket| timestamps[bucket] = [] }
          @mutex = Mutex.new
        end

        def wait_time_for(rate_limits)
          limits = Array(rate_limits).map { |rate_limit| normalize_rate_limit(rate_limit) }
          return 0.0 if limits.empty?

          now = @clock.call.to_f
          @mutex.synchronize do
            wait_time = limits.map { |rate_limit| wait_time_for_limit(rate_limit, now) }.max || 0.0
            record_limits(limits, now) unless wait_time.positive?
            wait_time
          end
        end

        private

        def normalize_rate_limit(rate_limit)
          normalized = RateLimitOptions.normalize_hash(rate_limit)
          key = normalized[:key].to_s.strip
          raise ArgumentError, "rate limit key must be present" if key.empty?

          normalized.merge(key: key)
        end

        def wait_time_for_limit(rate_limit, now)
          timestamps = active_timestamps(rate_limit, now)
          return 0.0 if timestamps.length < rate_limit[:limit]

          [timestamps.first + rate_limit[:interval] - now, 0.0].max
        end

        def record(rate_limit, now)
          active_timestamps(rate_limit, now) << now
        end

        def record_limits(limits, now)
          limits.uniq { |rate_limit| bucket_key(rate_limit) }.each do |rate_limit|
            record(rate_limit, now)
          end
        end

        def active_timestamps(rate_limit, now)
          timestamps = @timestamps_by_bucket[bucket_key(rate_limit)]
          cutoff = now - rate_limit[:interval]
          timestamps.shift while timestamps.first && timestamps.first <= cutoff
          timestamps
        end

        def bucket_key(rate_limit)
          [rate_limit[:key], rate_limit[:interval]]
        end
      end
    end
  end
end
