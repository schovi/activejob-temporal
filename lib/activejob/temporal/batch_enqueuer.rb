# frozen_string_literal: true

require_relative "batch_enqueue_result"

module ActiveJob
  module Temporal
    class BatchEnqueuer
      def initialize(enqueue:, validate_job:, validate_scheduled_at:)
        @enqueue_job = enqueue
        @validate_job = validate_job
        @validate_scheduled_at = validate_scheduled_at
      end

      def enqueue(items, concurrency: 1)
        entries = validate_entries!(items)
        concurrency = validate_concurrency!(concurrency)
        results = Array.new(entries.length)

        enqueue_entries(entries, results, concurrency)

        BatchEnqueueResult.new(results)
      end

      private

      attr_reader :enqueue_job, :validate_job, :validate_scheduled_at

      def validate_entries!(items)
        raise ArgumentError, "batch enqueue jobs must be an Enumerable" unless items.respond_to?(:each)

        errors = []
        entries = items.each_with_index.map do |item, index|
          validate_entry(item, index, errors)
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

        entry_queue = Queue.new
        entries.each { |entry| entry_queue << entry }
        worker_count = [concurrency, entries.length].min

        Array.new(worker_count) do
          Thread.new do
            loop do
              enqueue_entry(entry_queue.pop(true), results)
            rescue ThreadError
              break
            end
          end
        end.each(&:value)
      end

      def enqueue_sequentially(entries, results)
        entries.each { |entry| enqueue_entry(entry, results) }
      end

      def enqueue_entry(entry, results)
        handle = enqueue_job.call(entry[:job], scheduled_at: entry[:scheduled_at])
        results[entry[:index]] = success_result(entry, handle)
      rescue DuplicateEnqueueError => e
        results[entry[:index]] = duplicate_result(entry, e)
      rescue StandardError => e
        results[entry[:index]] = failed_result(entry, e)
      end

      def success_result(entry, handle)
        BatchEnqueueItemResult.new(
          index: entry[:index],
          job: entry[:job],
          status: :success,
          handle: handle
        )
      end

      def duplicate_result(entry, error)
        BatchEnqueueItemResult.new(
          index: entry[:index],
          job: entry[:job],
          status: :duplicate,
          error: error
        )
      end

      def failed_result(entry, error)
        BatchEnqueueItemResult.new(
          index: entry[:index],
          job: entry[:job],
          status: :failed,
          error: error
        )
      end
    end
  end
end
