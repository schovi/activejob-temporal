# frozen_string_literal: true

require "active_support/message_encryptor"
require "base64"
require "json"
require "openssl"
require "securerandom"
require "time"

module ActiveJob
  module Temporal
    module PayloadEncryption
      extend self

      CIPHER = "aes-256-gcm"
      LEGACY_VERSION = 1
      VERSION = 2
      DEFAULT_KEY_ID = "primary"
      KEY_ID_PATTERN = /\A[A-Za-z0-9_.:-]{1,128}\z/
      V2_IV_BYTES = 12
      KeyEntry = Struct.new(:id, :key, :decrypt_until, keyword_init: true)

      def encrypted?(payload)
        payload[:encrypted_payload] == true || payload["encrypted_payload"] == true
      end

      def encrypt(payload, config, context: nil)
        return encrypt_legacy(payload, config) unless context

        encrypt_v2(payload, config, context)
      end

      def decrypt(payload, config, context: nil)
        version = payload[:encrypted_payload_version] || payload["encrypted_payload_version"]
        return decrypt_legacy(payload, config) if version == LEGACY_VERSION
        return decrypt_v2(payload, config, context) if version == VERSION

        raise ActiveJob::SerializationError, "Unsupported encrypted payload version: #{version.inspect}"
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
        !key_entry(value, fallback_id: DEFAULT_KEY_ID).nil?
      end

      private

      def encrypt_legacy(payload, config)
        {
          encrypted_payload: true,
          encrypted_payload_version: LEGACY_VERSION,
          encrypted_data: encryptor(config).encrypt_and_sign(payload)
        }
      end

      def encrypt_v2(payload, config, context)
        key_entry = primary_key_entry(config)
        iv = SecureRandom.random_bytes(V2_IV_BYTES)
        cipher = OpenSSL::Cipher.new(CIPHER)
        cipher.encrypt
        cipher.key = key_entry.key
        cipher.iv = iv
        cipher.auth_data = authenticated_data(context, key_entry.id)
        encrypted_data = cipher.update(JSON.generate(payload)) + cipher.final

        {
          encrypted_payload: true,
          encrypted_payload_version: VERSION,
          encrypted_key_id: key_entry.id,
          encrypted_data: Base64.strict_encode64(encrypted_data),
          encrypted_iv: Base64.strict_encode64(iv),
          encrypted_auth_tag: Base64.strict_encode64(cipher.auth_tag)
        }
      end

      def decrypt_legacy(payload, config)
        encrypted_data = payload[:encrypted_data] || payload["encrypted_data"]
        normalize_top_level_keys(encryptor(config).decrypt_and_verify(encrypted_data))
      rescue ActiveSupport::MessageEncryptor::InvalidMessage
        raise ActiveJob::SerializationError, "Unable to decrypt ActiveJob::Temporal payload"
      end

      def decrypt_v2(payload, config, context)
        key_id = payload[:encrypted_key_id] || payload["encrypted_key_id"]
        key_entry = key_entry_for_id(config, key_id)
        plaintext = decrypt_v2_data(payload, key_entry, authenticated_data(context, key_id))
        normalize_top_level_keys(JSON.parse(plaintext))
      rescue ActiveJob::SerializationError
        raise
      rescue OpenSSL::Cipher::CipherError, JSON::ParserError, ArgumentError
        raise ActiveJob::SerializationError, "Unable to decrypt ActiveJob::Temporal payload"
      end

      def decrypt_v2_data(payload, key_entry, auth_data)
        cipher = OpenSSL::Cipher.new(CIPHER)
        cipher.decrypt
        cipher.key = key_entry.key
        cipher.iv = decode_envelope_field(payload, :encrypted_iv)
        cipher.auth_tag = decode_envelope_field(payload, :encrypted_auth_tag)
        cipher.auth_data = auth_data
        cipher.update(decode_envelope_field(payload, :encrypted_data)) + cipher.final
      end

      def decode_envelope_field(payload, key)
        value = payload[key] || payload[key.to_s]
        Base64.strict_decode64(value.to_s)
      rescue ArgumentError
        raise ActiveJob::SerializationError, "Unable to decrypt ActiveJob::Temporal payload"
      end

      def encryptor(config)
        primary_key = primary_key_entry(config).key
        encryptor = ActiveSupport::MessageEncryptor.new(primary_key, cipher: CIPHER, serializer: :json)

        old_key_entries(config).each do |key|
          next if expired_key?(key)

          encryptor.rotate(key.key, cipher: CIPHER, serializer: :json)
        end

        encryptor
      end

      def primary_key_entry(config)
        key_entry(config.encryption_key, fallback_id: DEFAULT_KEY_ID) ||
          raise(ConfigurationError, "Encryption keys must be Base64-encoded #{key_length}-byte values")
      end

      def key_entry_for_id(config, key_id)
        matching_key = ([primary_key_entry(config)] + old_key_entries(config)).find { |entry| entry.id == key_id }
        raise ActiveJob::SerializationError, "Unknown encrypted payload key id: #{key_id.inspect}" unless matching_key

        if expired_key?(matching_key)
          raise ActiveJob::SerializationError, "Encrypted payload key id #{key_id.inspect} is expired"
        end

        matching_key
      end

      def expired_key?(key_entry)
        key_entry.decrypt_until && key_entry.decrypt_until < Time.now.utc
      end

      def old_key_entries(config)
        config.encryption_old_keys.filter_map { |key| key_entry(key, fallback_id: nil) }
      end

      def key_entry(value, fallback_id:)
        id, raw_key, decrypt_until = key_parts(value, fallback_id)
        return if value.is_a?(Hash) && id.to_s.empty?
        return unless id.nil? || id.to_s.match?(KEY_ID_PATTERN)

        decoded_key = decode_key(raw_key)
        return unless decoded_key && decoded_key.bytesize == key_length

        parsed_decrypt_until = parse_decrypt_until(decrypt_until)
        return if decrypt_until && !parsed_decrypt_until

        KeyEntry.new(id: id, key: decoded_key, decrypt_until: parsed_decrypt_until)
      end

      def key_parts(value, fallback_id)
        return [fallback_id, value, nil] unless value.is_a?(Hash)

        [
          value[:id] || value["id"],
          value[:key] || value["key"],
          value[:decrypt_until] || value["decrypt_until"]
        ]
      end

      def parse_decrypt_until(value)
        return unless value
        return value.utc if value.respond_to?(:utc)

        Time.parse(value.to_s).utc
      rescue ArgumentError
        nil
      end

      def authenticated_data(context, key_id)
        JSON.generate(
          encrypted_key_id: key_id,
          encrypted_payload_version: VERSION,
          namespace: context_value(context, :namespace),
          workflow_id: context_value(context, :workflow_id)
        )
      end

      def context_value(context, key)
        raise ActiveJob::SerializationError, "Encrypted payload context requires #{key}" unless context.respond_to?(:[])

        value = context[key] || context[key.to_s]
        return value.to_s unless value.to_s.empty?

        raise ActiveJob::SerializationError, "Encrypted payload context requires #{key}"
      end

      def normalize_top_level_keys(payload)
        payload.each_with_object({}) do |(key, value), normalized|
          normalized[key.to_sym] = value
        end
      end
    end
  end
end
