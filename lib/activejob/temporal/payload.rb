# frozen_string_literal: true

require "json"
require "time"
require "active_job/arguments"

module ActiveJob
  module Temporal
    # Payload serialization and deserialization for ActiveJob.
    #
    # This module converts ActiveJob instances into JSON-serializable hash payloads
    # for transmission to Temporal workflows and activities. It also handles argument
    # deserialization back into Ruby objects.
    #
    # @note Payload Size Limit
    #   Temporal enforces a maximum payload size (configurable via `max_payload_size_kb`,
    #   default 250 KB). Large payloads will raise a SerializationError.
    #
    # @example Payload structure
    #   {
    #     job_class: "MyJob",
    #     job_id: "abc-123",
    #     queue_name: "default",
    #     arguments: [{"_aj_serialized"=>"ActiveJob::Serializers::ObjectSerializer", ...}],
    #     executions: 0,
    #     exception_executions: {},
    #     scheduled_at: "2025-10-29T12:00:00Z" # optional
    #   }
    module Payload
      extend self

      # Converts an ActiveJob instance into a serializable payload hash.
      #
      # @param job [ActiveJob::Base] The job instance to serialize
      # @param scheduled_at [Time, String, nil] Optional scheduled execution time
      #
      # @return [Hash] Serialized payload with keys:
      #   - :job_class [String] Fully-qualified job class name
      #   - :job_id [String] Unique job identifier
      #   - :queue_name [String] Target queue name
      #   - :arguments [Array] Serialized job arguments (via ActiveJob::Arguments)
      #   - :executions [Integer] Current execution count (default 0)
      #   - :exception_executions [Hash] Exception execution counts (default {})
      #   - :scheduled_at [String] ISO8601 timestamp (optional)
      #
      # @raise [ActiveJob::SerializationError] if arguments cannot be serialized
      # @raise [ActiveJob::SerializationError] if payload exceeds max_payload_size_kb
      # @raise [ArgumentError] if scheduled_at is not convertible to Time
      #
      # @example Basic job payload
      #   job = MyJob.new
      #   payload = Payload.from_job(job)
      #   # => { job_class: "MyJob", job_id: "...", arguments: [...], ... }
      #
      # @example Scheduled job payload
      #   job = MyJob.new
      #   payload = Payload.from_job(job, scheduled_at: 1.hour.from_now)
      #   # => { ..., scheduled_at: "2025-10-29T13:00:00Z" }
      def from_job(job, scheduled_at: nil)
        payload = {
          job_class: job.class.name,
          job_id: job.job_id,
          queue_name: job.queue_name,
          arguments: serialize_arguments(job.arguments || []),
          executions: job.executions || 0,
          exception_executions: job.exception_executions || {}
        }
        payload[:scheduled_at] = iso8601_timestamp(scheduled_at) if scheduled_at

        enforce_payload_size!(payload)
        payload
      end

      # Deserializes job arguments from a payload hash.
      #
      # Extracts the serialized arguments array from the payload and uses
      # ActiveJob's built-in deserialization to reconstruct Ruby objects
      # (including GlobalID references to ActiveRecord models).
      #
      # @param payload [Hash] Payload hash containing serialized arguments
      # @option payload [Array] :arguments Serialized arguments (required)
      #
      # @return [Array] Deserialized arguments array ready for job.perform(*args)
      #
      # @raise [ActiveJob::SerializationError] if deserialization fails
      #
      # @example Deserialize arguments
      #   payload = { arguments: [{"_aj_serialized"=>"..."}] }
      #   args = Payload.deserialize_args(payload)
      #   # => [actual_ruby_object]
      def deserialize_args(payload)
        serialized_args = payload[:arguments] || payload["arguments"]
        ActiveJob::Arguments.deserialize(serialized_args)
      rescue StandardError => e
        raise ActiveJob::SerializationError, e.message
      end

      private

      def serialize_arguments(arguments)
        ActiveJob::Arguments.serialize(arguments)
      rescue StandardError => e
        raise ActiveJob::SerializationError, e.message
      end

      def iso8601_timestamp(value)
        return value if value.is_a?(String) && valid_iso8601?(value)

        timestamp = if value.respond_to?(:iso8601)
                      value
                    elsif value.respond_to?(:to_time)
                      value.to_time
                    else
                      raise ArgumentError, "scheduled_at must be convertible to Time"
                    end
        timestamp.iso8601
      end

      def enforce_payload_size!(payload)
        json = JSON.generate(payload)
        max_size_kb = ActiveJob::Temporal.config.max_payload_size_kb || 250
        size_limit_bytes = max_size_kb * 1024
        return if json.bytesize <= size_limit_bytes

        actual_size_kb = (json.bytesize / 1024.0).round(1)
        message = format(
          "Job payload size (%<actual>.1f KB) exceeds maximum allowed size (%<max>d KB). " \
          "Consider reducing argument size or using references (e.g., database IDs).",
          actual: actual_size_kb,
          max: max_size_kb
        )
        raise ActiveJob::SerializationError, message
      end

      def valid_iso8601?(value)
        Time.iso8601(value)
        true
      rescue ArgumentError
        false
      end
    end
  end
end
