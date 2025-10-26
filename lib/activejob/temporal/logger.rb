# frozen_string_literal: true

require "json"
require "time"

module ActiveJob
  module Temporal
    module Logger
      extend self

      def log_event(event_name, attributes = {})
        log(:info, event_name, attributes)
      end

      def info(event_name, attributes = {})
        log(:info, event_name, attributes)
      end

      def warn(event_name, attributes = {})
        log(:warn, event_name, attributes)
      end

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
