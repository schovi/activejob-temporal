# frozen_string_literal: true

require "base64"

module ActiveJob
  module Temporal
    module PayloadSerializers
      module MessagePack
        extend self

        NAME = "message_pack"

        def dump(payload)
          envelope(Base64.strict_encode64(message_pack.pack(payload)))
        end

        def load(payload)
          normalize_top_level_keys(message_pack.unpack(serialized_data(payload)))
        rescue StandardError => e
          raise if e.is_a?(ConfigurationError)

          raise ActiveJob::SerializationError, "Unable to deserialize MessagePack payload: #{e.message}"
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

        def message_pack
          require "msgpack"
          ::MessagePack
        rescue LoadError
          raise ConfigurationError, 'MessagePack payload serialization requires applications to add gem "msgpack"'
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
