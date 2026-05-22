# frozen_string_literal: true

require "concurrent/map"

require_relative "../rate_limit_options"

module ActiveJob
  module Temporal
    module RateLimiters
      class MemoryBucketStore
        Bucket = Struct.new(:timestamps, :mutex, :last_touched_at, :references)
        SWEEP_INTERVAL = 1.0

        def initialize
          @buckets_by_key = Concurrent::Map.new
          @buckets_mutex = Mutex.new
          @next_sweep_at = nil
        end

        def acquire(keys, now)
          @buckets_mutex.synchronize do
            keys.uniq.sort.map do |key|
              bucket = bucket_for(key, now)
              bucket.references += 1
              [key, bucket]
            end
          end
        end

        def release(bucket_entries, now)
          @buckets_mutex.synchronize do
            bucket_entries.each do |key, bucket|
              bucket.references -= 1
              @buckets_by_key.delete_pair(key, bucket) if evictable_bucket?(key, bucket, now)
            end
          end
        end

        def synchronize(bucket_entries, &)
          synchronize_buckets(bucket_entries.map(&:last), &)
        end

        def touch(bucket_entries, now)
          bucket_entries.each do |entry|
            bucket = entry.fetch(1)
            bucket.last_touched_at = now unless bucket.timestamps.empty?
          end
        end

        def prune_expired_timestamps(bucket, interval, now)
          cutoff = now - interval
          timestamps = bucket.timestamps
          timestamps.shift while timestamps.first && timestamps.first <= cutoff
          timestamps
        end

        def sweep_if_due(now)
          return unless sweep_due?(now)

          bucket_entries = acquire_sweep_bucket_entries
          synchronize(bucket_entries) do
            bucket_entries.each do |key, bucket|
              prune_expired_timestamps(bucket, key.fetch(1), now)
            end
          end
        ensure
          release(bucket_entries, now) if bucket_entries
        end

        private

        def bucket_for(key, now)
          @buckets_by_key.compute_if_absent(key) { Bucket.new([], Mutex.new, now, 0) }
        end

        def sweep_due?(now)
          @buckets_mutex.synchronize do
            return false if @next_sweep_at && now < @next_sweep_at

            @next_sweep_at = now + SWEEP_INTERVAL
            true
          end
        end

        def acquire_sweep_bucket_entries
          @buckets_mutex.synchronize do
            @buckets_by_key.each_pair
                           .to_a
                           .sort_by(&:first)
                           .each_with_object([]) do |(key, bucket), bucket_entries|
              next unless bucket.references.zero?

              bucket.references += 1
              bucket_entries << [key, bucket]
            end
          end
        end

        def evictable_bucket?(key, bucket, now)
          bucket.references.zero? &&
            bucket.timestamps.empty? &&
            now - bucket.last_touched_at >= key.fetch(1)
        end

        def synchronize_buckets(buckets, index = 0, &)
          return yield if index == buckets.length

          buckets[index].mutex.synchronize do
            synchronize_buckets(buckets, index + 1, &)
          end
        end
      end

      # Process-local sliding-window limiter for development, tests, and single-worker setups.
      class Memory
        def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @clock = clock
          @bucket_store = MemoryBucketStore.new
        end

        def wait_time_for(rate_limits)
          limits = normalize_rate_limits(rate_limits)
          return 0.0 if limits.empty?

          now = @clock.call.to_f
          with_bucket_entries(limits, now) do |bucket_entries|
            wait_time_for_limits(limits, now, bucket_entries)
          end
        end

        private

        def normalize_rate_limits(rate_limits)
          Array(rate_limits).map { |rate_limit| normalize_rate_limit(rate_limit) }
        end

        def normalize_rate_limit(rate_limit)
          normalized = RateLimitOptions.normalize_hash(rate_limit)
          key = normalized[:key].to_s.strip
          raise ArgumentError, "rate limit key must be present" if key.empty?

          normalized.merge(key: key)
        end

        def wait_time_for_limit(rate_limit, now, bucket)
          timestamps = active_timestamps(rate_limit, now, bucket)
          return 0.0 if timestamps.length < rate_limit[:limit]

          [timestamps.first + rate_limit[:interval] - now, 0.0].max
        end

        def record(rate_limit, now, bucket)
          active_timestamps(rate_limit, now, bucket) << now
        end

        def record_limits(limits, now, bucket_entries_by_key)
          limits.uniq { |rate_limit| bucket_key(rate_limit) }.each do |rate_limit|
            record(rate_limit, now, bucket_entries_by_key.fetch(bucket_key(rate_limit)))
          end
        end

        def active_timestamps(rate_limit, now, bucket)
          @bucket_store.prune_expired_timestamps(bucket, rate_limit[:interval], now)
        end

        def bucket_key(rate_limit)
          [rate_limit[:key], rate_limit[:interval]].freeze
        end

        def bucket_keys_for(limits)
          limits.map { |rate_limit| bucket_key(rate_limit) }
        end

        def with_bucket_entries(limits, now)
          bucket_entries = @bucket_store.acquire(bucket_keys_for(limits), now)
          @bucket_store.synchronize(bucket_entries) do
            yield bucket_entries
          end
        ensure
          if bucket_entries
            @bucket_store.release(bucket_entries, now)
            @bucket_store.sweep_if_due(now)
          end
        end

        def wait_time_for_limits(limits, now, bucket_entries)
          bucket_entries_by_key = bucket_entries.to_h
          wait_time = limits.map do |rate_limit|
            wait_time_for_limit(rate_limit, now, bucket_entries_by_key.fetch(bucket_key(rate_limit)))
          end.max || 0.0
          record_limits(limits, now, bucket_entries_by_key) unless wait_time.positive?
          @bucket_store.touch(bucket_entries, now)
          wait_time
        end
      end
    end
  end
end
