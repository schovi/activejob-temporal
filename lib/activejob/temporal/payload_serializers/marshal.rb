# frozen_string_literal: true

require "base64"

module ActiveJob
  module Temporal
    module PayloadSerializers
      module Marshal
        extend self

        NAME = "marshal"

        def dump(payload)
          envelope(Base64.strict_encode64(::Marshal.dump(payload)))
        end

        def load(payload)
          # Marshal support is opt-in and only safe for trusted Temporal histories.
          # rubocop:disable Security/MarshalLoad
          normalize_top_level_keys(::Marshal.load(serialized_data(payload)))
          # rubocop:enable Security/MarshalLoad
        rescue StandardError => e
          raise ActiveJob::SerializationError, "Unable to deserialize Marshal payload: #{e.message}"
        end

        def envelope?(payload)
          (payload[:payload_serializer] || payload["payload_serializer"]) == NAME
        end

        private

        def envelope(serialized_data)
          {
            serialized_payload: true,
            payload_serializer: NAME,
            payload_serializer_version: PayloadSerializers::ENVELOPE_VERSION,
            serialized_data: serialized_data
          }
        end

        def serialized_data(payload)
          Base64.strict_decode64(payload[:serialized_data] || payload["serialized_data"])
        end

        def normalize_top_level_keys(payload)
          payload.each_with_object({}) do |(key, value), normalized|
            normalized[key.to_sym] = value
          end
        end
      end
    end
  end
end
