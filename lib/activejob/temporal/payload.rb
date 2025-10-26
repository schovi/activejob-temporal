# frozen_string_literal: true

require "json"
require "time"
require "active_job/arguments"

module ActiveJob
  module Temporal
    module Payload
      extend self

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
        size_limit_bytes = (ActiveJob::Temporal.config.max_payload_size_kb || 250) * 1024
        return if json.bytesize <= size_limit_bytes

        raise ActiveJob::SerializationError,
              format("Payload size %<size>d bytes exceeds limit of %<limit>d bytes",
                     size: json.bytesize, limit: size_limit_bytes)
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
