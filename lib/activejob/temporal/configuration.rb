# frozen_string_literal: true

require "logger"
require "active_support/core_ext/numeric/time"
require "active_model"

require_relative "middleware"
require_relative "payload_encryption"

# rubocop:disable Metrics/ModuleLength
module ActiveJob
  module Temporal
    LOCALE_PATH = File.expand_path("locales/en.yml", __dir__)
    I18n.load_path << LOCALE_PATH unless I18n.load_path.include?(LOCALE_PATH)

    # Base error class for all activejob-temporal errors.
    class Error < StandardError; end

    # Raised when configuration is invalid.
    #
    # @see Configuration#validate!
    class ConfigurationError < Error; end

    VALIDATION_LEVELS = %i[strict warn none].freeze
    METRICS_PROVIDERS = %i[none prometheus].freeze
    UNTRAPPABLE_SIGNALS = %w[KILL STOP].freeze

    # Central registry of all configuration attributes.
    #
    # This is the single source of truth for attribute names, types, defaults, and env vars.
    # Provides metadata for:
    # - Automatic attribute accessor generation
    # - Default value initialization (with lazy evaluation via Proc)
    # - Environment variable mapping (e.g., TEMPORAL_TARGET)
    # - Type information for validation and type coercion
    #
    # @example Accessing configuration metadata
    #   metadata = CONFIGURATION_ATTRIBUTES[:target]
    #   metadata[:default]      # => "127.0.0.1:7233"
    #   metadata[:env_var]      # => "TEMPORAL_TARGET"
    #   metadata[:type]         # => :string
    #   metadata[:description]  # => "Temporal server host:port"
    #
    # @api private
    CONFIGURATION_ATTRIBUTES = {
      # Connection Settings
      target: {
        default: "127.0.0.1:7233",
        env_var: "ACTIVEJOB_TEMPORAL_TARGET",
        type: :string,
        description: "Temporal server host:port"
      },

      namespace: {
        default: "default",
        env_var: "ACTIVEJOB_TEMPORAL_NAMESPACE",
        type: :string,
        description: "Temporal namespace"
      },

      task_queue_prefix: {
        default: nil,
        env_var: "ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX",
        type: :string,
        description: "Optional prefix for task queue names"
      },

      task_queue: {
        default: "default",
        env_var: "ACTIVEJOB_TEMPORAL_TASK_QUEUE",
        type: :string,
        description: "Default task queue name for workers"
      },

      tls: {
        default: nil,
        type: :object,
        description: "Optional SDK-native TLS options or hash-compatible TLS settings"
      },

      tls_cert_path: {
        default: nil,
        env_var: "ACTIVEJOB_TEMPORAL_TLS_CERT_PATH",
        type: :string,
        description: "Optional client certificate file path for mTLS"
      },

      tls_key_path: {
        default: nil,
        env_var: "ACTIVEJOB_TEMPORAL_TLS_KEY_PATH",
        type: :string,
        description: "Optional client private key file path for mTLS"
      },

      tls_server_root_ca_cert_path: {
        default: nil,
        env_var: "ACTIVEJOB_TEMPORAL_TLS_SERVER_ROOT_CA_CERT_PATH",
        type: :string,
        description: "Optional server root CA certificate file path for TLS verification"
      },

      tls_domain: {
        default: nil,
        env_var: "ACTIVEJOB_TEMPORAL_TLS_DOMAIN",
        type: :string,
        description: "Optional TLS SNI domain override"
      },

      tls_cert_watch: {
        default: false,
        env_var: "ACTIVEJOB_TEMPORAL_TLS_CERT_WATCH",
        type: :boolean,
        description: "Watch TLS certificate files and reload worker clients when they change"
      },

      tls_reload_signal: {
        default: "HUP",
        env_var: "ACTIVEJOB_TEMPORAL_TLS_RELOAD_SIGNAL",
        type: :string,
        description: "Signal used by workers to reload TLS certificates manually"
      },

      priority_task_queues: {
        default: -> { {} },
        type: :hash,
        description: "Optional mapping from numeric ActiveJob priority values to Temporal task queues"
      },

      workflow_id_generator: {
        default: nil,
        type: :callable,
        description: "Optional callable for custom Temporal workflow IDs"
      },

      # Timeouts (use Proc for lazy evaluation of ActiveSupport::Duration)
      default_activity_timeout: {
        default: -> { 15.minutes },
        type: :duration,
        description: "Default start_to_close_timeout for activity execution"
      },

      default_heartbeat_timeout: {
        default: nil,
        type: :duration,
        description: "Default heartbeat_timeout for activity execution (optional)"
      },

      default_schedule_to_start_timeout: {
        default: nil,
        type: :duration,
        description: "Default schedule_to_start_timeout for activity execution (optional)"
      },

      default_schedule_to_close_timeout: {
        default: nil,
        type: :duration,
        description: "Default schedule_to_close_timeout for activity execution (optional)"
      },

      default_retry_initial_interval: {
        default: -> { 30.seconds },
        type: :duration,
        description: "Initial retry interval"
      },

      # Retry Settings
      default_retry_backoff: {
        default: 2.0,
        type: :float,
        description: "Backoff coefficient for exponential retry"
      },

      default_retry_max_attempts: {
        default: 1,
        type: :integer,
        description: "Maximum retry attempts for activities"
      },

      # Observability
      logger: {
        default: lambda {
          (defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger) ||
            ::Logger.new($stdout)
        },
        type: :object,
        description: "Logger instance for gem output"
      },

      audit_log: {
        default: false,
        env_var: "ACTIVEJOB_TEMPORAL_AUDIT_LOG",
        type: :boolean,
        description: "Enable structured audit events for job lifecycle changes"
      },

      audit_logger: {
        default: nil,
        type: :object,
        description: "Optional logger instance for audit events; falls back to logger"
      },

      validation_level: {
        default: :strict,
        type: :symbol,
        description: "Configuration validation behavior: :strict, :warn, or :none"
      },

      enable_tracing: {
        default: true,
        type: :boolean,
        description: "Enable OpenTelemetry distributed tracing"
      },

      metrics_provider: {
        default: :none,
        env_var: "ACTIVEJOB_TEMPORAL_METRICS_PROVIDER",
        type: :symbol,
        description: "Metrics provider: :none or :prometheus"
      },

      metrics_port: {
        default: nil,
        env_var: "ACTIVEJOB_TEMPORAL_METRICS_PORT",
        type: :integer,
        description: "Optional HTTP port for Prometheus metrics at /metrics"
      },

      metrics_bind: {
        default: "127.0.0.1",
        env_var: "ACTIVEJOB_TEMPORAL_METRICS_BIND",
        type: :string,
        description: "Bind address for the Prometheus metrics endpoint"
      },

      middleware_chain: {
        default: -> { Middleware::Chain.new },
        type: :object,
        description: "Ordered middleware chain for activity job execution"
      },

      identity: {
        default: nil,
        type: :string,
        description: "Optional worker identity for observability"
      },

      # Payload & Performance
      max_payload_size_kb: {
        default: 250,
        env_var: "ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB",
        type: :integer,
        description: "Maximum job payload size in kilobytes"
      },

      encrypt_payload: {
        default: false,
        env_var: "ACTIVEJOB_TEMPORAL_ENCRYPT_PAYLOAD",
        type: :boolean,
        description: "Encrypt serialized job execution payloads before sending them to Temporal"
      },

      encryption_key: {
        default: nil,
        env_var: "ACTIVEJOB_TEMPORAL_ENCRYPTION_KEY",
        type: :string,
        description: "Base64-encoded 32-byte AES-256-GCM payload encryption key"
      },

      encryption_old_keys: {
        default: -> { [] },
        type: :array,
        description: "Base64-encoded previous payload encryption keys accepted for decryption"
      },

      enable_search_attributes: {
        default: true,
        type: :boolean,
        description: "Enable Temporal search attributes for job metadata"
      },

      max_concurrent_activities: {
        default: 100,
        env_var: "ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES",
        type: :integer,
        description: "Maximum concurrent activities per worker"
      },

      max_concurrent_workflow_tasks: {
        default: 5,
        env_var: "ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS",
        type: :integer,
        description: "Maximum concurrent workflow tasks per worker"
      }
    }.freeze

    # Configuration object for the activejob-temporal gem.
    #
    # Holds connection settings, timeouts, retry policies, and operational flags.
    # Use {ActiveJob::Temporal.configure} to set values with automatic validation.
    #
    # @note Thread Safety
    #   The global configuration object is synchronized by {Configurable} while
    #   configure blocks mutate it. Complete configuration during application boot.
    #
    # @note Environment Variable Defaults
    #   ACTIVEJOB_TEMPORAL_TARGET, ACTIVEJOB_TEMPORAL_NAMESPACE,
    #   ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX, ACTIVEJOB_TEMPORAL_TASK_QUEUE,
    #   ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB,
    #   ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES,
    #   ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS,
    #   ACTIVEJOB_TEMPORAL_METRICS_PROVIDER, ACTIVEJOB_TEMPORAL_METRICS_PORT, and
    #   ACTIVEJOB_TEMPORAL_METRICS_BIND can provide defaults.
    #
    # @see ConfigValidator
    # @see ActiveJob::Temporal.configure
    # @api private
    class Configuration
      attr_accessor :in_configure_block

      CONFIGURATION_ATTRIBUTES.each_key do |attribute|
        define_method(attribute) do
          @attributes[attribute]
        end

        define_method("#{attribute}=") do |value|
          @attributes[attribute] = value
          validate! unless @in_configure_block

          value
        end
      end

      def initialize
        @attributes = {}
        @in_configure_block = false
        CONFIGURATION_ATTRIBUTES.each do |attribute, metadata|
          @attributes[attribute] = resolve_default_value(metadata)
        end
      end

      def [](key)
        @attributes[key]
      end

      def []=(key, value)
        @attributes[key] = value
      end

      def add_middleware(middleware, ...)
        middleware_chain.add(middleware, ...)
      end

      def validate!
        return if validation_level == :none

        validator = build_validator
        return if validator.valid?

        handle_validation_errors(validator.errors)
      end

      def self.format_validation_errors(errors)
        messages = errors.full_messages
        return messages.first if messages.size == 1

        error_list = messages.each_with_index.map do |message, index|
          "  #{index + 1}. #{message}"
        end.join("\n")

        plural = "s" if messages.size > 1
        "Configuration validation failed with #{messages.size} error#{plural}:\n#{error_list}"
      end

      private

      def build_validator
        validator = ConfigValidator.new

        CONFIGURATION_ATTRIBUTES.each_key do |attribute|
          validator.public_send("#{attribute}=", @attributes[attribute])
        end

        validator
      end

      def handle_validation_errors(errors)
        message = self.class.format_validation_errors(errors)

        raise ConfigurationError, message unless validation_level == :warn

        logger.warn(message)
      end

      def resolve_default_value(metadata)
        if metadata[:env_var] && ENV[metadata[:env_var]]
          value = ENV[metadata[:env_var]]
          return convert_env_value(value, metadata[:type])
        end

        default = metadata[:default]
        default.is_a?(Proc) ? default.call : default
      end

      def convert_env_value(value, type)
        case type
        when :integer then value.to_i
        when :float then value.to_f
        when :boolean then value == "true"
        when :symbol then value.to_sym
        else value
        end
      end
    end

    # Validates ActiveJob::Temporal configuration.
    #
    # This class uses ActiveModel::Validations to provide declarative validation
    # with i18n support. Attributes are automatically synchronized from the
    # configuration via metaprogramming.
    #
    # **Validation Rules:**
    # - `target`: Presence + host:port format validation
    # - `namespace`: Presence + alphanumeric/hyphens/underscores format
    # - `default_activity_timeout`: Duration type + positive value
    # - `default_retry_initial_interval`: Duration type + positive value
    # - `default_retry_backoff`: Numericality >= 1.0
    # - `default_retry_max_attempts`: Numericality >= 0
    # - `max_payload_size_kb`: Numericality 1..2GB
    # - `max_concurrent_activities`: Numericality > 0
    # - `max_concurrent_workflow_tasks`: Numericality > 0
    # - `workflow_id_generator`: Optional callable
    # - `middleware_chain`: Callable chain with registration support
    #
    # @example Using ConfigValidator directly
    #   validator = ConfigValidator.new
    #   validator.target = "localhost:7233"
    #   validator.namespace = "production"
    #   if validator.valid?
    #     puts "Configuration is valid"
    #   else
    #     puts validator.errors.full_messages
    #   end
    #
    # @see ActiveJob::Temporal::Configuration.validate!
    # @api private
    # rubocop:disable Metrics/ClassLength
    class ConfigValidator
      include ActiveModel::Validations

      # Generate attr_accessor for all configuration attributes
      attr_accessor(*CONFIGURATION_ATTRIBUTES.keys)

      #
      # STANDARD VALIDATIONS
      # Use ActiveModel's built-in validators where possible
      #

      # Connection Settings
      validates :target,
                presence: { message: :target_required }

      validates :namespace,
                presence: { message: :namespace_required }

      # Retry Settings
      validates :default_retry_backoff,
                numericality: {
                  greater_than_or_equal_to: 1.0,
                  message: :retry_backoff_too_small,
                  allow_nil: false
                }

      validates :default_retry_max_attempts,
                numericality: {
                  greater_than_or_equal_to: 0,
                  only_integer: true,
                  message: :retry_max_attempts_negative,
                  allow_nil: false
                }

      # Payload & Performance
      validates :max_payload_size_kb,
                numericality: {
                  greater_than: 0,
                  less_than_or_equal_to: 2_097_152, # 2 GB in KB
                  only_integer: true,
                  message: :payload_size_invalid,
                  allow_nil: false
                }

      validates :max_concurrent_activities,
                numericality: {
                  greater_than: 0,
                  only_integer: true,
                  message: :concurrent_activities_invalid,
                  allow_nil: false
                }

      validates :max_concurrent_workflow_tasks,
                numericality: {
                  greater_than: 0,
                  only_integer: true,
                  message: :concurrent_workflow_tasks_invalid,
                  allow_nil: false
                }

      validates :validation_level,
                inclusion: {
                  in: VALIDATION_LEVELS,
                  message: :invalid_level
                }

      validates :metrics_provider,
                inclusion: {
                  in: METRICS_PROVIDERS,
                  message: :unsupported_provider
                }

      #
      # CUSTOM VALIDATORS
      # For complex logic that doesn't fit standard validators
      #

      validate :validate_target_format
      validate :validate_namespace_format
      validate :validate_duration_values
      validate :validate_workflow_id_generator
      validate :validate_middleware_chain
      validate :validate_priority_task_queues
      validate :validate_metrics_settings
      validate :validate_audit_settings
      validate :validate_encryption_settings
      validate :validate_tls_settings

      private

      # Validates target is in host:port format
      def validate_target_format
        return if target.blank? # presence validation handles nil/empty
        return if target =~ /^[\w.-]+:\d{1,5}$/

        errors.add(:target, :invalid_format, target: target)
      end

      # Validates namespace contains only alphanumeric, hyphens, underscores
      def validate_namespace_format
        return if namespace.blank?
        return if namespace =~ /^[\w-]+$/

        errors.add(:namespace, :invalid_format, namespace: namespace)
      end

      # Validates duration attributes are positive durations
      def validate_duration_values
        # Required duration attributes
        validate_duration_attribute(:default_activity_timeout, required: true)
        validate_duration_attribute(:default_retry_initial_interval, required: true)

        # Optional duration attributes
        validate_duration_attribute(:default_heartbeat_timeout, required: false)
        validate_duration_attribute(:default_schedule_to_start_timeout, required: false)
        validate_duration_attribute(:default_schedule_to_close_timeout, required: false)
      end

      def validate_workflow_id_generator
        return if workflow_id_generator.nil?

        unless workflow_id_generator.respond_to?(:call)
          errors.add(:workflow_id_generator, :not_callable, value: workflow_id_generator.inspect)
          return
        end

        return if callable_accepts_positional_job?(workflow_id_generator)

        errors.add(:workflow_id_generator, :wrong_arity, value: workflow_id_generator.inspect)
      end

      def validate_middleware_chain
        return if middleware_chain.respond_to?(:add) && middleware_chain.respond_to?(:call)

        errors.add(:middleware_chain, :invalid, value: middleware_chain.inspect)
      end

      def validate_priority_task_queues
        unless priority_task_queues.is_a?(Hash)
          errors.add(:priority_task_queues, :not_a_hash, value: priority_task_queues.inspect)
          return
        end

        if non_integer_priority_key
          errors.add(:priority_task_queues, :non_integer_priority, value: non_integer_priority_key.inspect)
          return
        end

        return unless blank_priority_task_queue

        errors.add(:priority_task_queues, :blank_queue, value: blank_priority_task_queue.inspect)
      end

      def non_integer_priority_key
        priority_task_queues.keys.find { |priority| !priority.is_a?(Integer) }
      end

      def blank_priority_task_queue
        priority_task_queues.values.find { |task_queue| task_queue.to_s.strip.empty? }
      end

      def validate_metrics_settings
        validate_metrics_port
        validate_metrics_bind
      end

      def validate_metrics_port
        return if metrics_port.nil?
        return if metrics_port.is_a?(Integer) && metrics_port.between?(1, 65_535)

        errors.add(:metrics_port, :invalid_port, value: metrics_port.inspect)
      end

      def validate_metrics_bind
        return if metrics_bind.to_s.strip.present?

        errors.add(:metrics_bind, :blank)
      end

      def validate_audit_settings
        validate_audit_log
        validate_audit_logger
      end

      def validate_audit_log
        return if [true, false].include?(audit_log)

        errors.add(:audit_log, :not_boolean, value: audit_log.inspect)
      end

      def validate_audit_logger
        return if audit_logger.nil? || audit_logger.respond_to?(:info)

        errors.add(:audit_logger, :invalid, value: audit_logger.inspect)
      end

      def validate_encryption_settings
        validate_encrypt_payload
        validate_encryption_key
        validate_encryption_old_keys
      end

      def validate_encrypt_payload
        return if [true, false].include?(encrypt_payload)

        errors.add(:encrypt_payload, :not_boolean, value: encrypt_payload.inspect)
      end

      def validate_encryption_key
        if encrypt_payload && encryption_key.to_s.empty?
          errors.add(:encryption_key, :required)
          return
        end

        return if encryption_key.nil? || PayloadEncryption.valid_key?(encryption_key)

        errors.add(:encryption_key, :invalid, bytes: PayloadEncryption.key_length, value: "[FILTERED]")
      end

      def validate_encryption_old_keys
        unless encryption_old_keys.is_a?(Array)
          errors.add(:encryption_old_keys, :not_an_array, value: encryption_old_keys.inspect)
          return
        end

        return if encryption_old_keys.all? { |key| PayloadEncryption.valid_key?(key) }

        errors.add(:encryption_old_keys, :invalid, bytes: PayloadEncryption.key_length, value: "[FILTERED]")
      end

      def validate_tls_settings
        validate_tls_cert_key_pair
        validate_tls_file_path(:tls_cert_path)
        validate_tls_file_path(:tls_key_path)
        validate_tls_file_path(:tls_server_root_ca_cert_path)
        validate_tls_domain
        validate_tls_cert_watch
        validate_tls_reload_signal
      end

      def validate_tls_cert_key_pair
        return if tls_cert_path.to_s.empty? == tls_key_path.to_s.empty?

        errors.add(:tls_cert_path, :requires_key_path)
      end

      def validate_tls_file_path(attribute)
        path = public_send(attribute)
        return if path.nil?

        unless path.is_a?(String) && path.strip.present?
          errors.add(attribute, :invalid_path, value: path.inspect)
          return
        end

        expanded_path = File.expand_path(path)
        return if File.file?(expanded_path) && File.readable?(expanded_path)

        errors.add(attribute, :unreadable_path, value: path)
      end

      def validate_tls_domain
        return if tls_domain.nil? || tls_domain.to_s.strip.present?

        errors.add(:tls_domain, :blank)
      end

      def validate_tls_cert_watch
        unless [true, false].include?(tls_cert_watch)
          errors.add(:tls_cert_watch, :not_boolean, value: tls_cert_watch.inspect)
          return
        end

        return unless tls_cert_watch && tls_watch_paths.empty?

        errors.add(:tls_cert_watch, :requires_paths)
      end

      def validate_tls_reload_signal
        unless tls_reload_signal.is_a?(String) && tls_reload_signal.strip.present?
          errors.add(:tls_reload_signal, :blank)
          return
        end

        normalized_signal = tls_reload_signal.sub(/\ASIG/i, "").upcase
        return if Signal.list.key?(normalized_signal) && !UNTRAPPABLE_SIGNALS.include?(normalized_signal)

        errors.add(:tls_reload_signal, :invalid, value: tls_reload_signal.inspect)
      end

      def tls_watch_paths
        [tls_cert_path, tls_key_path, tls_server_root_ca_cert_path].compact.reject { |path| path.to_s.strip.empty? }
      end

      def callable_accepts_positional_job?(callable)
        arity = callable.respond_to?(:arity) ? callable.arity : callable.method(:call).arity

        arity == 1 || arity.negative?
      end

      def validate_duration_attribute(attr_name, required: true)
        value = public_send(attr_name)

        # Allow nil for optional attributes
        return if value.nil? && !required

        # Check if it's a duration-like object (Numeric or ActiveSupport::Duration)
        unless value.is_a?(Numeric) || value.is_a?(ActiveSupport::Duration)
          errors.add(attr_name, :not_a_duration, value: value.inspect)
          return
        end

        # Check if positive
        seconds = value.to_f
        return if seconds.positive?

        errors.add(attr_name, :duration_not_positive,
                   seconds: seconds,
                   attribute: attr_name.to_s.humanize.downcase)
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
# rubocop:enable Metrics/ModuleLength
