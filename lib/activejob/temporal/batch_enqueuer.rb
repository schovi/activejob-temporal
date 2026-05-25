# frozen_string_literal: true

require_relative "batch_enqueue_result"

module ActiveJob
  module Temporal
    class BatchEnqueuer
      MAX_BATCH_SIZE = 10_000
      QUEUE_STOP = Object.new.freeze

      def initialize(enqueue:, validate_job:, validate_scheduled_at:)
        @enqueue_job = enqueue
        @validate_job = validate_job
        @validate_scheduled_at = validate_scheduled_at
      end

      def enqueue(items, concurrency: 1)
        concurrency = validate_concurrency!(concurrency)
        entries = validate_entries!(items)
        results = Array.new(entries.length)

        enqueue_entries(entries, results, concurrency)

        BatchEnqueueResult.new(results)
      end

      private

      attr_reader :enqueue_job, :validate_job, :validate_scheduled_at

      def validate_entries!(items)
        raise ArgumentError, "batch enqueue jobs must be an Enumerable" unless items.respond_to?(:each)

        validate_batch_size_hint!(items)

        errors = []
        entries = []
        items.each.with_index do |item, index|
          raise_batch_size_error! if index >= MAX_BATCH_SIZE

          entries << validate_entry(item, index, errors)
        end

        raise ArgumentError, "batch enqueue jobs cannot be empty" if entries.empty?
        raise BatchEnqueueValidationError, errors if errors.any?

        entries
      end

      def validate_entry(item, index, errors)
        entry = normalize_entry(item)
        entry[:index] = index
        validate_job.call(entry[:job])
        entry[:scheduled_at] = validate_scheduled_at.call(entry[:scheduled_at])
        entry
      rescue StandardError => e
        errors << {
          index: index,
          error: "#{e.class}: #{e.message}"
        }
        nil
      end

      def validate_batch_size_hint!(items)
        return unless items.respond_to?(:size)

        size = items.size
        return if size.nil? || size <= MAX_BATCH_SIZE

        raise_batch_size_error!
      end

      def raise_batch_size_error!
        raise ArgumentError,
              "batch enqueue accepts at most #{MAX_BATCH_SIZE} jobs; split larger inputs into smaller batches"
      end

      def normalize_entry(item)
        return { job: item, scheduled_at: nil } if active_job_instance?(item)

        raise ArgumentError, "must be an ActiveJob instance or a Hash with :job" unless item.respond_to?(:to_hash)

        hash = item.to_hash
        job = hash[:job] || hash["job"]
        scheduled_at = hash[:scheduled_at] || hash["scheduled_at"]
        raise ArgumentError, "must include an ActiveJob instance in :job" unless active_job_instance?(job)

        { job: job, scheduled_at: scheduled_at }
      end

      def active_job_instance?(value)
        value.respond_to?(:job_id) && value.respond_to?(:queue_name)
      end

      def validate_concurrency!(concurrency)
        concurrency = Integer(concurrency)
        raise ArgumentError unless concurrency.positive?

        concurrency
      rescue ArgumentError, TypeError
        raise ArgumentError, "batch enqueue concurrency must be a positive integer"
      end

      def enqueue_entries(entries, results, concurrency)
        return enqueue_sequentially(entries, results) if concurrency == 1

        worker_count = [concurrency, entries.length].min
        entry_queue = SizedQueue.new(worker_count)

        workers = Array.new(worker_count) do
          Thread.new do
            loop do
              entry = entry_queue.pop
              break if entry.equal?(QUEUE_STOP)

              enqueue_entry(entry, results)
            end
          end
        end

        entries.each { |entry| entry_queue << entry }
        worker_count.times { entry_queue << QUEUE_STOP }
        workers.each(&:value)
      end

      def enqueue_sequentially(entries, results)
        entries.each { |entry| enqueue_entry(entry, results) }
      end

      def enqueue_entry(entry, results)
        handle = enqueue_job.call(entry[:job], scheduled_at: entry[:scheduled_at])
        results[entry[:index]] = item_result(entry, status: :success, handle: handle)
      rescue DuplicateEnqueueError => e
        results[entry[:index]] = item_result(entry, status: :duplicate, error: e)
      rescue StandardError => e
        results[entry[:index]] = item_result(entry, status: :failed, error: e)
      end

      def item_result(entry, status:, handle: nil, error: nil)
        BatchEnqueueItemResult.new(
          index: entry[:index],
          job: entry[:job],
          status: status,
          handle: handle,
          error: error
        )
      end
    end
  end
end
