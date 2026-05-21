# frozen_string_literal: true

require "active_support/message_encryptor"
require "base64"

module ActiveJob
  module Temporal
    module PayloadEncryption
      extend self

      CIPHER = "aes-256-gcm"
      VERSION = 1

      def encrypted?(payload)
        payload[:encrypted_payload] == true || payload["encrypted_payload"] == true
      end

      def encrypt(payload, config)
        {
          encrypted_payload: true,
          encrypted_payload_version: VERSION,
          encrypted_data: encryptor(config).encrypt_and_sign(payload)
        }
      end

      def decrypt(payload, config)
        version = payload[:encrypted_payload_version] || payload["encrypted_payload_version"]
        unless version == VERSION
          raise ActiveJob::SerializationError, "Unsupported encrypted payload version: #{version.inspect}"
        end

        encrypted_data = payload[:encrypted_data] || payload["encrypted_data"]
        normalize_top_level_keys(encryptor(config).decrypt_and_verify(encrypted_data))
      rescue ActiveSupport::MessageEncryptor::InvalidMessage
        raise ActiveJob::SerializationError, "Unable to decrypt ActiveJob::Temporal payload"
      end

      def key_length
        ActiveSupport::MessageEncryptor.key_len(CIPHER)
      end

      def decode_key(value)
        Base64.strict_decode64(value.to_s)
      rescue ArgumentError
        nil
      end

      def valid_key?(value)
        decoded_key = decode_key(value)
        decoded_key && decoded_key.bytesize == key_length
      end

      private

      def encryptor(config)
        primary_key = decoded_primary_key(config.encryption_key)
        encryptor = ActiveSupport::MessageEncryptor.new(primary_key, cipher: CIPHER, serializer: :json)

        config.encryption_old_keys.each do |key|
          encryptor.rotate(decoded_primary_key(key), cipher: CIPHER, serializer: :json)
        end

        encryptor
      end

      def decoded_primary_key(value)
        decoded_key = decode_key(value)
        return decoded_key if decoded_key && decoded_key.bytesize == key_length

        raise ConfigurationError, "Encryption keys must be Base64-encoded #{key_length}-byte values"
      end

      def normalize_top_level_keys(payload)
        payload.each_with_object({}) do |(key, value), normalized|
          normalized[key.to_sym] = value
        end
      end
    end
  end
end
