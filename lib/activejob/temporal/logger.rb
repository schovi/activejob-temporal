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
    #   If the SemanticLogger constant is defined, log entries are passed directly as hashes
    #   to SemanticLogger (which handles JSON formatting). Otherwise, the module JSON-stringifies
    #   the payload before passing it to the configured Ruby Logger instance.
    #
    # @example Basic logging
    #   Logger.info("job.enqueued", job_id: "123", queue: "default")
    #   # => { "event": "job.enqueued", "timestamp": "2025-10-29T12:00:00Z", "job_id": "123", "queue": "default" }
    #
    # @example Error logging
    #   Logger.error("job.failed", job_id: "123", error: "NetworkError")
    #
    # @example With SemanticLogger
    #   # If SemanticLogger is available, structured hash is passed directly
    #   Logger.info("workflow.started", workflow_id: "wf-123")
    #   # SemanticLogger formats as structured JSON
    #
    # @example Without SemanticLogger
    #   # Falls back to JSON.generate before calling logger.info
    #   Logger.info("workflow.started", workflow_id: "wf-123")
    #   # => '{"event":"workflow.started","timestamp":"2025-10-31T12:00:00Z","workflow_id":"wf-123"}'
    module Logger
      extend self

      # Logs an event at INFO level.
      #
      # @param event_name [String, Symbol] Name of the event (e.g., "job.enqueued")
      # @param attributes [Hash] Additional structured data to include in log entry
      # @return [void]
      # @raise [ArgumentError] if event_name is not a String or Symbol
      # @raise [ArgumentError] if attributes is not a Hash
      # @example
      #   Logger.log_event("workflow.started", workflow_id: "wf-123", job_class: "MyJob")
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
      # @example
      #   Logger.error("job.failed", job_id: "123", error_class: "RuntimeError", message: "Boom")
      def error(event_name, attributes = {})
        log(:error, event_name, attributes)
      end

      private

      def log(level, event_name, attributes)
        validate_event!(event_name)
        attributes = normalize_attributes(attributes)

        payload = build_payload(event_name, attributes)
        configured_logger = ActiveJob::Temporal.config.logger
        return unless configured_logger.respond_to?(level)

        if semantic_logger_available?
          configured_logger.public_send(level, payload)
        else
          configured_logger.public_send(level, JSON.generate(payload))
        end
      end

      def build_payload(event_name, attributes)
        { event: event_name, timestamp: current_timestamp }.merge(attributes)
      end

      def current_timestamp
        Time.now.utc.iso8601
      end

      def normalize_attributes(attributes)
        case attributes
        when nil then {}
        when Hash then attributes.dup
        else
          raise ArgumentError, "attributes must be a Hash"
        end
      end

      def validate_event!(event_name)
        return if event_name.is_a?(String) || event_name.is_a?(Symbol)

        raise ArgumentError, "event_name must be a String or Symbol"
      end

      def semantic_logger_available?
        defined?(SemanticLogger)
      end
    end
  end
end
