# frozen_string_literal: true

require "logger"
require "active_support/core_ext/numeric/time"
require "active_support/ordered_options"
require "concurrent/mvar"

require_relative "temporal/version"
require_relative "temporal/configuration"
require_relative "temporal/client"
require_relative "temporal/logger"
require_relative "temporal/payload"
require_relative "temporal/search_attributes"
require_relative "temporal/retry_mapper"
require_relative "temporal/temporal_options"
require_relative "temporal/workflow_enqueuer"
require_relative "temporal/adapter"
require_relative "temporal/workflows/aj_workflow"
require_relative "temporal/activities/aj_runner_activity"
require_relative "temporal/cancel"

# Load i18n locales for configuration validation messages
I18n.load_path << File.expand_path("temporal/locales/en.yml", __dir__)

module ActiveJob
  # ActiveJob adapter for Temporal workflow orchestration.
  #
  # This gem provides a durable, fault-tolerant execution backend for Rails ActiveJob
  # by leveraging Temporal's workflow engine. Jobs are executed as Temporal workflows
  # with automatic retries, scheduling, and observability.
  #
  # @example Basic configuration
  #   ActiveJob::Temporal.configure do |config|
  #     config.target = "temporal.example.com:7233"
  #     config.namespace = "production"
  #     config.task_queue_prefix = "my-app"
  #   end
  #
  # @example Using the adapter in a job
  #   class MyJob < ApplicationJob
  #     self.queue_adapter = :temporal
  #
  #     def perform(arg1, arg2)
  #       # Job logic here
  #     end
  #   end
  #
  # @example Complete configuration with error handling
  #   begin
  #     ActiveJob::Temporal.configure do |config|
  #       config.target = "temporal.example.com:7233"
  #       config.namespace = "production"
  #       config.default_activity_timeout = 10.minutes
  #       config.max_payload_size_kb = 250
  #     end
  #     ActiveJob::Temporal.config.validate!
  #   rescue ActiveJob::Temporal::ConfigurationError => e
  #     Rails.logger.error("Temporal configuration invalid: #{e.message}")
  #     raise
  #   end
  #
  # @see https://github.com/temporalio/sdk-ruby Temporal Ruby SDK
  module Temporal
    # Base error class for all activejob-temporal errors.
    class Error < StandardError; end

    # Raised when configuration is invalid.
    #
    # @see Configuration#validate!
    class ConfigurationError < Error; end

    # Raised when attempting to cancel a job that does not exist.
    #
    # @see Cancel.cancel
    class WorkflowNotFoundError < Error; end

    # Raised when Temporal cluster is unreachable.
    #
    # @see Client.build
    # @see Cancel.cancel
    class TemporalConnectionError < Error; end

    # Configuration object for the activejob-temporal gem.
    #
    # Holds connection settings, timeouts, retry policies, and operational flags.
    # This is a configuration wrapper that uses {ConfigValidator} for declarative,
    # i18n-ready validation.
    #
    # Use {ActiveJob::Temporal.configure} to set configuration values with automatic validation.
    #
    # @note Thread Safety
    #   The configuration object is thread-safe for both reading and writing.
    #   Concurrent reads are safe at any time. Configuration changes are synchronized
    #   using Concurrent::MVar to ensure exclusive access during modifications.
    #   For best practices, complete configuration during application initialization.
    #
    # @note Environment Variable Defaults
    #   Several configuration values can be set via environment variables:
    #   ACTIVEJOB_TEMPORAL_TARGET, ACTIVEJOB_TEMPORAL_NAMESPACE, ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX,
    #   ACTIVEJOB_TEMPORAL_TASK_QUEUE, ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB,
    #   ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES, ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS.
    #   Configuration attributes take precedence over env vars.
    #
    # @note Validation
    #   Configuration is automatically validated when using {.configure} with a block.
    #   Call {#validate!} explicitly if modifying config directly.
    #
    # @example Using the configure method (recommended)
    #   # Validation happens automatically at end of block
    #   ActiveJob::Temporal.configure do |config|
    #     config.target = "temporal.example.com:7233"
    #     config.namespace = "production"
    #     config.default_activity_timeout = 10.minutes
    #     config.default_retry_max_attempts = 3
    #   end
    #
    # @example Accessing configuration
    #   ActiveJob::Temporal.config.target
    #   # => "temporal.example.com:7233"
    #
    # @example Manual validation (rarely needed)
    #   ActiveJob::Temporal.config.target = "new-host:7233"
    #   ActiveJob::Temporal.config.validate!
    #
    # @see ConfigValidator
    # @see .configure
    # @api private
    class Configuration
      # Create a new Configuration instance with all defaults
      def initialize
        @attributes = {}
        @in_configure_block = false
        CONFIGURATION_ATTRIBUTES.each do |attr, metadata|
          default_value = Temporal.resolve_default_value(metadata)
          @attributes[attr] = default_value
        end
      end

      # Track whether we're inside a configure block
      attr_accessor :in_configure_block

      # Get attribute value
      def [](key)
        @attributes[key]
      end

      # Set attribute value
      def []=(key, value)
        @attributes[key] = value
      end

      # Dynamic attribute access
      def method_missing(method, *args)
        method_str = method.to_s
        if method_str.end_with?("=")
          handle_attribute_setter(method_str[0..-2].to_sym, args[0])
        elsif args.empty?
          handle_attribute_getter(method.to_sym)
        else
          super
        end
      end

      # Check if attribute is defined
      def respond_to_missing?(method, include_private = false)
        method_name = method.to_s
        if method_name.end_with?("=")
          attr_name = method_name[0..-2].to_sym
          return CONFIGURATION_ATTRIBUTES.key?(attr_name)
        end
        attr_name = method.to_sym
        CONFIGURATION_ATTRIBUTES.key?(attr_name) || super
      end

      # Validates all configuration settings using ConfigValidator
      def validate!
        validator = ConfigValidator.new

        # Sync all attributes from config to validator
        CONFIGURATION_ATTRIBUTES.each_key do |attr|
          validator.public_send("#{attr}=", @attributes[attr])
        end

        raise ConfigurationError, format_errors(validator.errors) unless validator.valid?
      end

      private

      # Handles dynamic getter for attributes
      def handle_attribute_getter(attr_name)
        return @attributes[attr_name] if CONFIGURATION_ATTRIBUTES.key?(attr_name)

        raise NoMethodError, "undefined method `#{attr_name}' for #{self.class}"
      end

      # Handles dynamic setter for attributes
      # Note: Explicit setters (e.g., default_activity_timeout=) take precedence
      # and handle their own validation, so this is only called for attributes
      # without explicit setters.
      def handle_attribute_setter(attr_name, value)
        return unless CONFIGURATION_ATTRIBUTES.key?(attr_name)

        @attributes[attr_name] = value

        # Validate immediately unless we're in a configure block
        validate! unless @in_configure_block

        value
      end

      # Formats ActiveModel errors for ConfigurationError message.
      def format_errors(errors)
        messages = errors.full_messages
        return messages.first if messages.size == 1

        error_list = messages.each_with_index.map do |msg, i|
          "  #{i + 1}. #{msg}"
        end.join("\n")

        plural = "s" if messages.size > 1
        "Configuration validation failed with #{messages.size} error#{plural}:\n#{error_list}"
      end
    end

    class << self
      # Returns the global configuration object.
      #
      # This method is memoized and returns the same Configuration instance
      # across multiple calls within the same process.
      #
      # @return [Configuration] the gem configuration
      def config
        @config_mvar ||= Concurrent::MVar.new(Configuration.new)
        @config_mvar.value
      end
      alias configuration config

      # Returns the memoized Temporal client connection for the process.
      #
      # The client is connected to the Temporal server specified in the configuration.
      # TLS options can be provided via configuration attributes or environment variables:
      # - TEMPORAL_TLS_CERT: TLS certificate
      # - TEMPORAL_TLS_KEY: TLS private key
      # - TEMPORAL_TLS_SERVER_NAME: TLS server name
      #
      # @return [Temporalio::Client] the connected Temporal client
      # @raise [ActiveJob::Temporal::Error] if connection fails due to network or authentication issues
      # @raise [ActiveJob::Temporal::TemporalConnectionError] if Temporal cluster is unreachable
      # @raise [Errno::ECONNREFUSED] if Temporal cluster is not accepting connections
      # @raise [SocketError] if Temporal hostname cannot be resolved
      # @raise [OpenSSL::SSL::SSLError] if TLS configuration is invalid
      # @example Get the client
      #   client = ActiveJob::Temporal.client
      #   client.list_workflows(query: "ajQueue='default'")
      #
      # @example Using client for workflow queries
      #   client = ActiveJob::Temporal.client
      #   workflows = client.list_workflows(query: "ajClass='MyJob'")
      #   workflows.each { |wf| puts wf.id }
      #
      # @example Accessing workflow handles
      #   client = ActiveJob::Temporal.client
      #   handle = client.workflow_handle("ajwf:MyJob:abc-123")
      #   result = handle.result
      #
      # @see Client.build
      def client
        @client ||= Client.build(config)
      end

      # Cancels a running or scheduled job by job ID.
      #
      # This method terminates the Temporal workflow associated with the job.
      # Cancellation is asynchronous and best-effort: the job will stop only if
      # it is actively heartbeating. See Cancel module documentation for details.
      #
      # @param job_class [Class] the ActiveJob class (used to determine task queue)
      # @param job_id [String] the unique job identifier
      # @return [Boolean, nil] false if workflow already completed, nil if cancellation requested
      # @raise [ActiveJob::Temporal::WorkflowNotFoundError] if job never existed or already removed from history
      # @raise [ActiveJob::Temporal::TemporalConnectionError] if Temporal cluster is unreachable
      # @example Cancel a scheduled job
      #   ActiveJob::Temporal.cancel(MyJob, "job-123-abc")
      # @example Handle cancellation outcomes
      #   result = ActiveJob::Temporal.cancel(MyJob, "abc-123")
      #   case result
      #   when false
      #     puts "Job already completed"
      #   when nil
      #     puts "Cancellation requested"
      #   end
      #
      # @example Cancel with error handling
      #   begin
      #     ActiveJob::Temporal.cancel(MyJob, "unknown-id")
      #   rescue ActiveJob::Temporal::WorkflowNotFoundError
      #     puts "Job does not exist"
      #   end
      #
      # @note Cancellation Requires Heartbeating
      #   For jobs to respond to cancellation, they must check for cancellation by heartbeating
      #   or polling Temporalio::Activity::Context.current.cancelled?. Without heartbeating,
      #   long-running activities will complete before they detect the cancellation signal.
      #
      # @see Cancel.cancel
      def cancel(job_class, job_id)
        Cancel.cancel(job_class, job_id)
      end

      # Configures the gem with a block and automatically validates.
      #
      # Yields the configuration object to the block for setting attributes.
      # Automatically validates configuration after the block executes.
      # If no block is given, returns the current configuration.
      #
      # @yield [config] Gives the configuration object to the block
      # @yieldparam config [ActiveSupport::OrderedOptions] the configuration to modify
      # @return [ActiveSupport::OrderedOptions] the configuration object
      # @raise [ConfigurationError] if validation fails after configuration
      # @example Basic configuration
      #   ActiveJob::Temporal.configure do |config|
      #     config.target = "temporal.example.com:7233"
      #     config.namespace = "production"
      #     config.default_activity_timeout = 10.minutes
      #   end
      #   # Validation happens automatically - no need to call validate!
      #
      # @example Configuration for development
      #   ActiveJob::Temporal.configure do |config|
      #     config.target = "localhost:7233"
      #     config.namespace = "default"
      #     config.enable_search_attributes = false
      #     config.max_payload_size_kb = 500
      #   end
      #
      # @example Getting config without block
      #   config = ActiveJob::Temporal.configure
      #   puts config.target  # => "127.0.0.1:7233"
      def configure
        return config unless block_given?

        # Use MVar's borrow to ensure exclusive access during configuration
        @config_mvar ||= Concurrent::MVar.new(Configuration.new)
        @config_mvar.borrow do |cfg|
          # Track that we're in a configure block
          cfg.in_configure_block = true

          begin
            yield(cfg)
          ensure
            # Always clear flag, even if block raises exception
            cfg.in_configure_block = false
          end
        end

        validate! # Automatic validation after configuration
      end

      # Validates the current configuration.
      #
      # Synchronizes configuration to validator, runs validations,
      # and raises ConfigurationError if invalid.
      #
      # This method is called automatically by configure, but can also
      # be called explicitly if needed (e.g., after modifying config directly).
      #
      # @return [void]
      # @raise [ConfigurationError] if validation fails
      # @example Explicit validation (rarely needed)
      #   ActiveJob::Temporal.config.target = "localhost:7233"
      #   ActiveJob::Temporal.validate! # Explicit call
      def validate!
        validator = build_validator
        raise ConfigurationError, format_validation_errors(validator.errors) unless validator.valid?
      end

      private

      # Builds validator with current configuration values.
      # Uses metaprogramming to sync all attributes automatically.
      #
      # @return [ConfigValidator] populated validator instance
      # @api private
      def build_validator
        validator = ConfigValidator.new

        # Automatically sync all attributes from config to validator
        CONFIGURATION_ATTRIBUTES.each_key do |attr|
          config_value = config.public_send(attr)
          validator.public_send("#{attr}=", config_value)
        end

        validator
      end

      # Formats ActiveModel errors for ConfigurationError message.
      #
      # @param errors [ActiveModel::Errors] validation errors
      # @return [String] formatted error message
      # @api private
      def format_validation_errors(errors)
        messages = errors.full_messages
        return messages.first if messages.size == 1

        error_list = messages.each_with_index.map do |msg, i|
          "  #{i + 1}. #{msg}"
        end.join("\n")

        plural = "s" if messages.size > 1
        "Configuration validation failed with #{messages.size} error#{plural}:\n#{error_list}"
      end
    end

    # Resolves default value for an attribute from metadata.
    # Checks environment variables first, then uses default.
    #
    # @param metadata [Hash] attribute metadata
    # @return [Object] resolved default value
    # @api private
    def self.resolve_default_value(metadata)
      # Check for environment variable
      if metadata[:env_var] && ENV[metadata[:env_var]]
        value = ENV[metadata[:env_var]]
        return convert_env_value(value, metadata[:type])
      end

      # Use default (evaluate if Proc)
      default = metadata[:default]
      default.is_a?(Proc) ? default.call : default
    end

    # Converts environment variable string to appropriate type.
    #
    # @param value [String] environment variable value
    # @param type [Symbol] target type
    # @return [Object] converted value
    # @api private
    def self.convert_env_value(value, type)
      case type
      when :integer then value.to_i
      when :float then value.to_f
      when :boolean then value == "true"
      else value
      end
    end
  end
end
