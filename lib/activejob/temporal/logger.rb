# frozen_string_literal: true

require "json"
require "time"

module ActiveJob
  module Temporal
    # Structured logging for activejob-temporal gem.
    #
    # This module provides structured JSON logging with event names and typed attributes.
    # It integrates with SemanticLogger if available, otherwise falls back to standard
    # Ruby Logger with JSON formatting.
    #
    # All log entries include:
    # - event: Event name (String or Symbol)
    # - timestamp: ISO8601 UTC timestamp
    # - Custom attributes (Hash)
    #
    # @note SemanticLogger Detection
    #   If the configured logger is a SemanticLogger instance, log entries are passed directly
    #   as hashes. Otherwise, the module JSON-stringifies the payload before passing it to the
    #   configured Ruby Logger instance.
    #
    # @example Basic logging
    #   Logger.info("job.enqueued", job_id: "123", queue: "default")
    #   # => { "event": "job.enqueued", "timestamp": "2025-10-29T12:00:00Z", "job_id": "123", "queue": "default" }
    #
    # @example Error logging
    #   Logger.error("job.failed", job_id: "123", error: "NetworkError")
    #
    # @example With SemanticLogger
    #   # If the configured logger is SemanticLogger, structured hash is passed directly
    #   Logger.info("workflow.started", workflow_id: "wf-123")
    #   # SemanticLogger formats as structured JSON
    #
    # @example Without SemanticLogger
    #   # Falls back to JSON.generate before calling logger.info
    #   Logger.info("workflow.started", workflow_id: "wf-123")
    #   # => '{"event":"workflow.started","timestamp":"2025-10-31T12:00:00Z","workflow_id":"wf-123"}'
    module Logger
      extend self

      CONTROL_CHARACTER_PATTERN = /[[:cntrl:]]/

      # Logs an event at INFO level.
      #
      # @param event_name [String, Symbol] Name of the event (e.g., "job.enqueued")
      # @param attributes [Hash] Additional structured data to include in log entry
      # @return [void]
      # @raise [ArgumentError] if event_name is not a String or Symbol
      # @raise [ArgumentError] if attributes is not a Hash
      # @raise [NoMethodError] if logger is not configured
      # @example
      #   Logger.log_event("workflow.started", workflow_id: "wf-123", job_class: "MyJob")
      #
      # @example With complex attributes
      #   Logger.log_event("job.completed", {
      #     job_id: "abc-123",
      #     duration_ms: 1500,
      #     result: { success: true, records_processed: 100 }
      #   })
      def log_event(event_name, attributes = {})
        log(:info, event_name, attributes)
      end

      # Logs an event at INFO level.
      #
      # @param event_name [String, Symbol] Name of the event
      # @param attributes [Hash] Additional structured data
      # @return [void]
      # @raise [ArgumentError] if event_name is not a String or Symbol
      # @raise [ArgumentError] if attributes is not a Hash
      # @raise [NoMethodError] if logger is not configured
      # @example
      #   Logger.info("job.completed", job_id: "123", duration_ms: 1500)
      def info(event_name, attributes = {})
        log(:info, event_name, attributes)
      end

      # Logs an event at WARN level.
      #
      # @param event_name [String, Symbol] Name of the event
      # @param attributes [Hash] Additional structured data
      # @return [void]
      # @raise [ArgumentError] if event_name is not a String or Symbol
      # @raise [ArgumentError] if attributes is not a Hash
      # @raise [NoMethodError] if logger is not configured
      # @example
      #   Logger.warn("job.retry", job_id: "123", attempt: 2, error: "Timeout")
      def warn(event_name, attributes = {})
        log(:warn, event_name, attributes)
      end

      # Logs an event at ERROR level.
      #
      # @param event_name [String, Symbol] Name of the event
      # @param attributes [Hash] Additional structured data
      # @return [void]
      # @raise [ArgumentError] if event_name is not a String or Symbol
      # @raise [ArgumentError] if attributes is not a Hash
      # @raise [NoMethodError] if logger is not configured
      # @example
      #   Logger.error("job.failed", job_id: "123", error_class: "RuntimeError", message: "Boom")
      def error(event_name, attributes = {})
        log(:error, event_name, attributes)
      end

      def log_to(configured_logger, level, event_name, attributes = {})
        log(level, event_name, attributes, configured_logger: configured_logger)
      end

      private

      # Internal logging method that handles all log levels.
      # @api private
      def log(level, event_name, attributes, configured_logger: ActiveJob::Temporal.config.logger)
        validate_event!(event_name)
        attributes = normalize_attributes(attributes)

        payload = build_payload(sanitize_log_value(event_name), sanitize_log_value(attributes))
        return unless configured_logger.respond_to?(level)

        if semantic_logger?(configured_logger)
          configured_logger.public_send(level, payload)
        else
          configured_logger.public_send(level, JSON.generate(payload))
        end
      end

      def sanitize_log_value(value)
        case value
        when String
          escape_control_characters(value)
        when Symbol
          sanitize_symbol(value)
        when Hash
          value.each_with_object({}) do |(key, nested_value), result|
            result[sanitize_log_key(key)] = sanitize_log_value(nested_value)
          end
        when Array
          value.map { |element| sanitize_log_value(element) }
        else
          value
        end
      end

      def sanitize_log_key(key)
        case key
        when String
          escape_control_characters(key)
        when Symbol
          sanitize_symbol(key)
        else
          key
        end
      end

      def sanitize_symbol(value)
        sanitized = escape_control_characters(value.to_s)
        sanitized == value.to_s ? value : sanitized
      end

      def escape_control_characters(value)
        return value unless value.match?(CONTROL_CHARACTER_PATTERN)

        value.gsub(CONTROL_CHARACTER_PATTERN) { |character| format("\\u%04X", character.ord) }
      end

      # Builds structured log payload with event and timestamp.
      # @api private
      def build_payload(event_name, attributes)
        { event: event_name, timestamp: current_timestamp }.merge(attributes)
      end

      # Returns current UTC timestamp in ISO8601 format.
      # @api private
      def current_timestamp
        Time.now.utc.iso8601
      end

      # Normalizes attributes to a hash.
      # @api private
      def normalize_attributes(attributes)
        case attributes
        when nil then {}
        when Hash then attributes.dup
        else
          raise ArgumentError, "attributes must be a Hash"
        end
      end

      # Validates event_name is a String or Symbol.
      # @api private
      def validate_event!(event_name)
        return if event_name.is_a?(String) || event_name.is_a?(Symbol)

        raise ArgumentError, "event_name must be a String or Symbol"
      end

      # Checks if the configured logger handles structured payloads itself.
      # @api private
      def semantic_logger?(configured_logger)
        return false unless defined?(SemanticLogger)
        return true if semantic_logger_instance?(configured_logger)

        configured_logger.class.name.to_s.start_with?("SemanticLogger::")
      end

      def semantic_logger_instance?(configured_logger)
        defined?(SemanticLogger::Logger) && configured_logger.is_a?(SemanticLogger::Logger)
      end
    end
  end
end
