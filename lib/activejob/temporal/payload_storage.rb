# frozen_string_literal: true

require "json"

require_relative "logger"

module ActiveJob
  module Temporal
    module PayloadStorage
      extend self

      VERSION = 1
      REFERENCE_KEY = :external_payload_reference

      def external?(payload)
        payload[:external_payload] == true || payload["external_payload"] == true
      end

      def offload_if_needed(payload, config:, metadata:, workflow_control_fields:)
        return payload unless configured?(config)
        return payload unless payload_exceeds_threshold?(payload, config)

        reference = dump_payload(payload, config, metadata)
        envelope = {
          external_payload: true,
          external_payload_version: VERSION,
          REFERENCE_KEY => reference
        }
        preserve_workflow_control_fields(payload, envelope, workflow_control_fields)
      end

      def load(payload, config:, workflow_control_fields:)
        return payload unless external?(payload)

        version = payload[:external_payload_version] || payload["external_payload_version"]
        unless version == VERSION
          raise ActiveJob::SerializationError, "Unsupported external payload version: #{version.inspect}"
        end

        loaded_payload = load_payload(payload, config)
        preserve_workflow_control_fields(payload, loaded_payload, workflow_control_fields)
      end

      def delete(payload, config:)
        return unless external?(payload)

        adapter = storage_adapter(config)
        return unless adapter.respond_to?(:delete)

        adapter.delete(payload_reference(payload))
      rescue StandardError => e
        ActiveJob::Temporal::Logger.warn(
          "payload_storage_delete_failed",
          error_class: e.class.name,
          error_message: e.message
        )
      end

      private

      def configured?(config)
        !config.payload_storage_adapter.nil? && !config.payload_storage_threshold_kb.nil?
      end

      def payload_exceeds_threshold?(payload, config)
        JSON.generate(payload).bytesize > (config.payload_storage_threshold_kb * 1024)
      end

      def dump_payload(payload, config, metadata)
        storage_adapter(config).dump(payload, metadata: metadata.compact)
      rescue ActiveJob::SerializationError
        raise
      rescue StandardError => e
        raise ActiveJob::SerializationError, "Unable to store external payload: #{e.message}"
      end

      def load_payload(payload, config)
        loaded_payload = storage_adapter(config).load(payload_reference(payload))
        return loaded_payload if loaded_payload.is_a?(Hash)

        raise ActiveJob::SerializationError, "External payload adapter returned #{loaded_payload.class}, expected Hash"
      end

      def storage_adapter(config)
        config.payload_storage_adapter ||
          raise(ActiveJob::SerializationError, "External payload requires payload_storage_adapter")
      end

      def payload_reference(payload)
        payload[REFERENCE_KEY] || payload[REFERENCE_KEY.to_s]
      end

      def preserve_workflow_control_fields(source_payload, target_payload, workflow_control_fields)
        workflow_control_fields.each do |key|
          value = source_payload[key] || source_payload[key.to_s]
          target_payload[key] = value if value
        end

        target_payload
      end
    end
  end
end
