# frozen_string_literal: true

require_relative "configuration"

module ActiveJob
  module Temporal
    class BatchEnqueueValidationError < Error
      attr_reader :errors

      def initialize(errors)
        @errors = errors
        super("Invalid batch enqueue jobs: #{format_errors(errors)}")
      end

      private

      def format_errors(errors)
        errors.map { |error| "item #{error[:index]} #{error[:error]}" }.join(", ")
      end
    end

    class BatchEnqueueItemResult
      attr_reader :index, :job, :status, :handle, :error

      def initialize(index:, job:, status:, handle: nil, error: nil)
        @index = index
        @job = job
        @status = status
        @handle = handle
        @error = error
      end

      def success?
        status == :success
      end

      def duplicate?
        status == :duplicate
      end

      def failure?
        status == :failed
      end

      def to_h
        {
          index: index,
          job_class: job.class.name,
          job_id: job.job_id,
          status: status,
          handle: handle,
          error: formatted_error
        }.compact
      end

      private

      def formatted_error
        return unless error

        "#{error.class}: #{error.message}"
      end
    end

    class BatchEnqueueResult
      attr_reader :results

      def initialize(results)
        @results = results
      end

      def success?
        failures.empty?
      end

      def successes
        results.select(&:success?)
      end

      def duplicates
        results.select(&:duplicate?)
      end

      def failures
        results.select(&:failure?)
      end

      def success_count
        successes.length
      end

      def duplicate_count
        duplicates.length
      end

      def failure_count
        failures.length
      end

      def to_h
        {
          success_count: success_count,
          duplicate_count: duplicate_count,
          failure_count: failure_count,
          results: results.map(&:to_h)
        }
      end
    end
  end
end
