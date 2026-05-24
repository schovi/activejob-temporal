# frozen_string_literal: true

require "json"
require "time"
require "active_support"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/string/conversions"
require "active_job/serializers"
require "active_job/arguments"

require_relative "payload_encryption"
require_relative "payload_storage"
require_relative "payload_serializers"
require_relative "observability"

module ActiveJob
  module Temporal
    # rubocop:disable Metrics/ModuleLength
    # Payload serialization and deserialization for ActiveJob.
    #
    # This module converts ActiveJob instances into JSON-serializable hash payloads
    # for transmission to Temporal workflows and activities. It also handles argument
    # deserialization back into Ruby objects.
    #
    # @note Payload Size Limit
    #   Temporal enforces a maximum payload size (configurable via `max_payload_size_kb`,
    #   default 250 KB). Large payloads will raise a SerializationError with a human-readable
    #   message indicating the actual size and the limit. Consider passing database IDs or
    #   S3 keys instead of large objects.
    #
    # @note GlobalID Serialization
    #   ActiveRecord models are automatically serialized using GlobalID. This requires the
    #   model to exist in the database at enqueue time and still exist at execution time.
    #   If the record is deleted, deserialization will fail.
    #
    # @example Payload structure
    #   {
    #     job_class: "MyJob",
    #     job_id: "abc-123",
    #     queue_name: "default",
    #     arguments: [{"_aj_serialized"=>"ActiveJob::Serializers::ObjectSerializer", ...}],
    #     executions: 0,
    #     exception_executions: {},
    #     scheduled_at: "2025-10-29T12:00:00Z" # optional
    #   }
    #
    # @see https://edgeapi.rubyonrails.org/classes/ActiveJob/Arguments.html ActiveJob Arguments Serialization
    module Payload
      extend self

      PAYLOAD_WARNING_THRESHOLD = 0.8
      PAYLOAD_NEAR_LIMIT_THRESHOLD = 0.9
      WORKFLOW_CONTROL_FIELDS = %i[
        scheduled_at
        default_activity_options
        retry_policy
        temporal_options
        dead_letter
        rate_limits
        workflow_interactions
        child_workflows
        chain
        dependencies
        dependency_failure_policy
        activity_task_queue
        continue_as_new
        workflow_state
        local_activity_helpers
        observability
      ].freeze

      # Converts an ActiveJob instance into a serializable payload hash.
      #
      # @param job [ActiveJob::Base] The job instance to serialize
      # @param scheduled_at [Time, String, nil] Optional scheduled execution time
      #
      # @return [Hash] Serialized payload with keys:
      #   - :job_class [String] Fully-qualified job class name
      #   - :job_id [String] Unique job identifier
      #   - :queue_name [String] Target queue name
      #   - :arguments [Array] Serialized job arguments (via ActiveJob::Arguments)
      #   - :executions [Integer] Current execution count (default 0)
      #   - :exception_executions [Hash] Exception execution counts (default {})
      #   - :scheduled_at [String] ISO8601 timestamp (optional)
      #
      # @raise [ActiveJob::SerializationError] if arguments cannot be serialized
      # @raise [ActiveJob::SerializationError] if payload exceeds max_payload_size_kb (includes actual size in message)
      # @raise [ArgumentError] if scheduled_at is not convertible to Time
      # @raise [ArgumentError] if job is nil
      # @raise [NoMethodError] if job does not respond to required attributes
      # @raise [JSON::GeneratorError] if payload cannot be JSON-serialized
      #
      # @example Basic job payload
      #   job = MyJob.new
      #   payload = Payload.from_job(job)
      #   # => { job_class: "MyJob", job_id: "...", arguments: [...], ... }
      #
      # @example Scheduled job payload
      #   job = MyJob.new
      #   payload = Payload.from_job(job, scheduled_at: 1.hour.from_now)
      #   # => { ..., scheduled_at: "2025-10-29T13:00:00Z" }
      #
      # @example Handling payload size errors
      #   begin
      #     MyJob.perform_later(large_object)
      #   rescue ActiveJob::SerializationError => e
      #     Rails.logger.error("Payload too large: #{e.message}")
      #     # Recommendation: Pass ID instead of full object
      #     MyJob.perform_later(large_object.id)
      #   end
      #
      # @example GlobalID serialization (ActiveRecord models)
      #   user = User.find(123)
      #   MyJob.perform_later(user)  # Serializes as GlobalID
      #   # Payload contains: { "_aj_globalid" => "gid://app/User/123" }
      #
      # @example Non-serializable object error
      #   begin
      #     MyJob.perform_later(File.open("/tmp/file.txt"))
      #   rescue ActiveJob::SerializationError => e
      #     # => "Unsupported argument type: File"
      #     Rails.logger.error(e.message)
      #   end
      #
      # @note Record Lifecycle Caveat
      #   When using GlobalID serialization for ActiveRecord models, the record MUST
      #   exist in the database at both enqueue time AND execution time. If the record
      #   is deleted before the job executes, deserialization will fail with
      #   ActiveRecord::RecordNotFound.
      #
      # @note Payload Size Optimization
      #   To reduce payload size, prefer passing database IDs instead of full ActiveRecord
      #   objects. For example, pass user.id instead of user. This is especially important
      #   for jobs with large argument lists or complex nested objects.
      # rubocop:disable Metrics/AbcSize
      def from_job(
        job,
        scheduled_at: nil,
        enforce_size: true,
        config: ActiveJob::Temporal.config,
        **options
      )
        encrypt = options.fetch(:encrypt, true)
        offload = options.fetch(:offload, enforce_size)
        encryption_context = options[:encryption_context]
        storage_metadata = options[:storage_metadata]
        payload = {
          job_class: job.class.name,
          job_id: job.job_id,
          queue_name: job.queue_name,
          arguments: serialize_arguments(job.arguments || []),
          executions: job.executions || 0,
          exception_executions: job.exception_executions || {}
        }
        payload[:scheduled_at] = iso8601_timestamp(scheduled_at) if scheduled_at

        scheduled_timestamp = payload.delete(:scheduled_at)
        final_payload = serializer_for(config).dump(payload)
        final_payload[:scheduled_at] = scheduled_timestamp if scheduled_timestamp
        final_payload = encrypt_payload_for_transport(final_payload, encrypt, config, encryption_context)
        final_payload = offload_payload_for_transport(final_payload, storage_metadata, config) if offload
        enforce_size!(final_payload, metrics_payload: payload, config: config) if enforce_size
        final_payload
      end
      # rubocop:enable Metrics/AbcSize

      # Deserializes job arguments from a payload hash.
      #
      # Extracts the serialized arguments array from the payload and uses
      # ActiveJob's built-in deserialization to reconstruct Ruby objects
      # (including GlobalID references to ActiveRecord models).
      #
      # @param payload [Hash] Payload hash containing serialized arguments
      # @option payload [Array] :arguments Serialized arguments (required)
      #
      # @return [Array] Deserialized arguments array ready for job.perform(*args)
      #
      # @raise [ActiveJob::SerializationError] if deserialization fails
      # @raise [GlobalID::RecordNotFound] if a GlobalID reference points to a deleted record
      #
      # @example Deserialize arguments
      #   payload = { arguments: [{"_aj_serialized"=>"..."}] }
      #   args = Payload.deserialize_args(payload)
      #   # => [actual_ruby_object]
      #
      # @example GlobalID deserialization with deleted record
      #   begin
      #     payload = { arguments: [{"_aj_globalid"=>"gid://app/User/999"}] }
      #     args = Payload.deserialize_args(payload)
      #   rescue ActiveRecord::RecordNotFound => e
      #     # Record was deleted between enqueue and execution
      #     Rails.logger.warn("Job argument no longer exists: #{e.message}")
      #   end
      def deserialize_args(payload, config: ActiveJob::Temporal.config, encryption_context: nil)
        deserialize_payload_args(deserialize_payload(payload, config: config, encryption_context: encryption_context))
      end

      def deserialize_payload_args(payload)
        serialized_args = payload[:arguments] || payload["arguments"]
        ActiveJob::Arguments.deserialize(serialized_args)
      rescue ActiveJob::SerializationError, ActiveJob::Temporal::ConfigurationError
        raise
      rescue StandardError => e
        raise ActiveJob::SerializationError, e.message
      end

      def deserialize_payload(payload, config: ActiveJob::Temporal.config, encryption_context: nil)
        stored_payload = PayloadStorage.load(
          payload,
          config: config,
          workflow_control_fields: WORKFLOW_CONTROL_FIELDS
        )
        transport_payload = decrypt_transport_payload(stored_payload, config, encryption_context)

        execution_payload = serializer_for_transport_payload(transport_payload, config).load(transport_payload)
        preserve_workflow_control_fields(transport_payload, execution_payload)
      end

      def encrypt_payload(payload, config: ActiveJob::Temporal.config, encryption_context: nil)
        encrypt_payload_if_configured(payload, config, encryption_context: encryption_context)
      end

      def offload_payload(payload, metadata:, config: ActiveJob::Temporal.config)
        PayloadStorage.offload_if_needed(
          payload,
          config: config,
          metadata: metadata,
          workflow_control_fields: WORKFLOW_CONTROL_FIELDS
        )
      end

      def delete_external_payload(payload, config: ActiveJob::Temporal.config)
        PayloadStorage.delete(payload, config: config)
      end

      def enforce_size!(payload, metrics_payload: payload, config: ActiveJob::Temporal.config)
        json = JSON.generate(payload)
        max_size_kb = config.max_payload_size_kb || 250
        size_limit_bytes = max_size_kb * 1024
        actual_size_kb = json.bytesize / 1024.0
        usage_ratio = json.bytesize.to_f / size_limit_bytes

        Observability.emit(
          :payload_serialize,
          Observability.attributes_from_payload(metrics_payload, bytes: json.bytesize)
        )
        log_payload_size(metrics_payload, actual_size_kb, max_size_kb, usage_ratio)
        return if json.bytesize <= size_limit_bytes

        message = format(
          "Job payload size (%<actual>.1f KB) exceeds maximum allowed size (%<max>d KB). " \
          "Consider reducing argument size or using references (e.g., database IDs).",
          actual: actual_size_kb,
          max: max_size_kb
        )
        raise ActiveJob::SerializationError, message
      end

      private

      # Plaintext copies keep workflow replay config-free; ciphertext keeps activities
      # from trusting tampered envelope controls after decryption.
      def encrypt_payload_for_transport(payload, encrypt, config, encryption_context)
        return payload unless encrypt

        encrypt_payload(payload, config: config, encryption_context: encryption_context)
      end

      def offload_payload_for_transport(payload, storage_metadata, config)
        offload_payload(payload, metadata: storage_metadata || {}, config: config)
      end

      def decrypt_transport_payload(payload, config, encryption_context)
        return payload unless PayloadEncryption.encrypted?(payload)

        decrypted_payload = PayloadEncryption.decrypt(payload, config, context: encryption_context)
        preserve_workflow_control_fields(payload, decrypted_payload, fields: %i[scheduled_at])
      end

      def encrypt_payload_if_configured(payload, config, encryption_context:)
        return payload unless config.encrypt_payload

        execution_payload = payload.except(:scheduled_at)
        encrypted_payload = PayloadEncryption.encrypt(execution_payload, config, context: encryption_context)
        copy_payload_serializer_metadata(payload, encrypted_payload)
        preserve_workflow_control_fields(payload, encrypted_payload)
        encrypted_payload
      end

      def preserve_workflow_control_fields(source_payload, decrypted_payload, fields: WORKFLOW_CONTROL_FIELDS)
        fields.each do |key|
          value = source_payload[key] || source_payload[key.to_s]
          decrypted_payload[key] = value if value
        end

        decrypted_payload
      end

      def serializer_for(config)
        PayloadSerializers.fetch(config.payload_serializer)
      end

      def serializer_for_transport_payload(payload, config)
        configured_serializer = PayloadSerializers.normalize_name(config.payload_serializer)
        payload_serializer = payload_serializer_name(payload)
        unless payload_serializer == configured_serializer
          message = "Payload serializer mismatch: " \
                    "configured #{configured_serializer.inspect}, payload #{payload_serializer.inspect}"
          raise ActiveJob::SerializationError,
                message
        end

        validate_payload_serializer_version!(payload) if payload_serializer_metadata?(payload)
        PayloadSerializers.fetch(configured_serializer)
      end

      def payload_serializer_name(payload)
        serializer_name = payload[:payload_serializer] || payload["payload_serializer"]
        return PayloadSerializers::JSON unless serializer_name

        PayloadSerializers.normalize_name(serializer_name)
      end

      def payload_serializer_metadata?(payload)
        payload.key?(:payload_serializer) || payload.key?("payload_serializer")
      end

      def validate_payload_serializer_version!(payload)
        version = payload[:payload_serializer_version] || payload["payload_serializer_version"]
        return if version == PayloadSerializers::ENVELOPE_VERSION

        raise ActiveJob::SerializationError, "Unsupported payload serializer version: #{version.inspect}"
      end

      def copy_payload_serializer_metadata(source_payload, encrypted_payload)
        %i[payload_serializer payload_serializer_version].each do |key|
          value = source_payload[key] || source_payload[key.to_s]
          encrypted_payload[key] = value if value
        end
      end

      # Serializes job arguments using ActiveJob's built-in serializer.
      # @api private
      def serialize_arguments(arguments)
        ActiveJob::Arguments.serialize(arguments)
      rescue StandardError => e
        raise ActiveJob::SerializationError, e.message
      end

      # Converts a value to ISO8601 timestamp string.
      # @api private
      def iso8601_timestamp(value)
        return value if value.is_a?(String) && valid_iso8601?(value)

        timestamp = if value.respond_to?(:iso8601)
                      value
                    elsif value.respond_to?(:to_time)
                      value.to_time
                    else
                      raise ArgumentError, "scheduled_at must be convertible to Time"
                    end
        raise ArgumentError, "scheduled_at must be convertible to Time" unless timestamp.respond_to?(:iso8601)

        timestamp.iso8601
      end

      def log_payload_size(payload, actual_size_kb, max_size_kb, usage_ratio)
        return if usage_ratio < PAYLOAD_WARNING_THRESHOLD

        attributes = payload_size_log_attributes(payload, actual_size_kb, max_size_kb, usage_ratio)

        if usage_ratio > 1.0
          ActiveJob::Temporal::Logger.error("payload_size_exceeded", attributes)
        elsif usage_ratio >= PAYLOAD_NEAR_LIMIT_THRESHOLD
          ActiveJob::Temporal::Logger.warn("payload_size_near_limit", attributes)
        elsif usage_ratio >= PAYLOAD_WARNING_THRESHOLD
          ActiveJob::Temporal::Logger.info("payload_size_large", attributes)
        end
      end

      def payload_size_log_attributes(payload, actual_size_kb, max_size_kb, usage_ratio)
        {
          job_class: payload[:job_class] || payload["job_class"],
          size_kb: actual_size_kb.round(1),
          limit_kb: max_size_kb,
          percentage: (usage_ratio * 100).round(1)
        }
      end

      # Checks if a string is valid ISO8601 format.
      # @api private
      def valid_iso8601?(value)
        Time.iso8601(value)
        true
      rescue ArgumentError
        false
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
