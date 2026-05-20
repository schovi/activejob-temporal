# frozen_string_literal: true

require "logger"
require "active_support/core_ext/numeric/time"
require "active_model"

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

      enable_tracing: {
        default: true,
        type: :boolean,
        description: "Enable OpenTelemetry distributed tracing"
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
    #   ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES, and
    #   ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS can provide defaults.
    #
    # @see ConfigValidator
    # @see ActiveJob::Temporal.configure
    # @api private
    class Configuration
      def initialize
        @attributes = {}
        @in_configure_block = false
        CONFIGURATION_ATTRIBUTES.each do |attribute, metadata|
          @attributes[attribute] = resolve_default_value(metadata)
        end
      end

      attr_accessor :in_configure_block

      def [](key)
        @attributes[key]
      end

      def []=(key, value)
        @attributes[key] = value
      end

      def method_missing(method, *args)
        method_name = method.to_s
        if method_name.end_with?("=")
          handle_attribute_setter(method_name[0..-2].to_sym, args[0])
        elsif args.empty?
          handle_attribute_getter(method.to_sym)
        else
          super
        end
      end

      def respond_to_missing?(method, include_private = false)
        method_name = method.to_s
        if method_name.end_with?("=")
          attribute_name = method_name[0..-2].to_sym
          return CONFIGURATION_ATTRIBUTES.key?(attribute_name)
        end

        attribute_name = method.to_sym
        CONFIGURATION_ATTRIBUTES.key?(attribute_name) || super
      end

      def validate!
        validator = ConfigValidator.new

        CONFIGURATION_ATTRIBUTES.each_key do |attribute|
          validator.public_send("#{attribute}=", @attributes[attribute])
        end

        raise ConfigurationError, self.class.format_validation_errors(validator.errors) unless validator.valid?
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

      def handle_attribute_getter(attribute_name)
        return @attributes[attribute_name] if CONFIGURATION_ATTRIBUTES.key?(attribute_name)

        raise NoMethodError, "undefined method `#{attribute_name}' for #{self.class}"
      end

      def handle_attribute_setter(attribute_name, value)
        return unless CONFIGURATION_ATTRIBUTES.key?(attribute_name)

        @attributes[attribute_name] = value
        validate! unless @in_configure_block

        value
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

      #
      # CUSTOM VALIDATORS
      # For complex logic that doesn't fit standard validators
      #

      validate :validate_target_format
      validate :validate_namespace_format
      validate :validate_duration_values

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
  end
end
