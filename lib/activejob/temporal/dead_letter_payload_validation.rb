# frozen_string_literal: true

module ActiveJob
  module Temporal
    module DeadLetterPayloadValidation
      extend self

      def validate!(payload)
        validate_metadata!(payload_value(payload, :dead_letter), "dead_letter.queue")

        Array(payload_value(payload, :chain)).each do |chain_step|
          validate_metadata!(payload_value(chain_step, :dead_letter), "chain.dead_letter.queue")
        end
      end

      private

      def validate_metadata!(metadata, queue_path)
        return unless metadata
        return if payload_value(metadata, :queue).to_s.strip.present?

        raise ConfigurationError, "#{queue_path} cannot be blank"
      end

      def payload_value(payload, key)
        return unless payload.respond_to?(:[])

        payload[key] || payload[key.to_s]
      rescue TypeError
        nil
      end
    end
  end
end
