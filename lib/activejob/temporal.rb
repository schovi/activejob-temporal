# frozen_string_literal: true

require "logger"
require "active_support/core_ext/numeric/time"

require_relative "temporal/version"
require_relative "temporal/client"
require_relative "temporal/logger"
require_relative "temporal/payload"
require_relative "temporal/search_attributes"
require_relative "temporal/retry_mapper"
require_relative "temporal/adapter"
require_relative "temporal/workflows/aj_workflow"
require_relative "temporal/activities/aj_runner_activity"
require_relative "temporal/cancel"

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
  # @see https://github.com/temporalio/sdk-ruby Temporal Ruby SDK
  module Temporal
    class Error < StandardError; end
    class ConfigurationError < Error; end

    # Configuration object for the activejob-temporal gem.
    #
    # Holds connection settings, timeouts, retry policies, and operational flags.
    # Use {ActiveJob::Temporal.configure} to set configuration values.
    #
    # @example
    #   ActiveJob::Temporal.configure do |config|
    #     config.target = "temporal.example.com:7233"
    #     config.namespace = "production"
    #     config.default_activity_timeout = 10.minutes
    #     config.default_retry_max_attempts = 3
    #   end
    class Configuration
      # @!attribute [rw] target
      #   @return [String] Temporal server host:port (default: "127.0.0.1:7233")
      # @!attribute [rw] namespace
      #   @return [String] Temporal namespace (default: "default")
      # @!attribute [rw] task_queue_prefix
      #   @return [String, nil] Optional prefix for task queue names (default: nil)
      # @!attribute [rw] default_retry_backoff
      #   @return [Float] Backoff coefficient for exponential retry (default: 2.0)
      # @!attribute [rw] default_retry_max_attempts
      #   @return [Integer] Maximum retry attempts for activities (default: 1)
      # @!attribute [rw] logger
      #   @return [Logger] Logger instance for gem output (default: Rails.logger or $stdout)
      # @!attribute [rw] enable_tracing
      #   @return [Boolean] Enable OpenTelemetry distributed tracing (default: true)
      # @!attribute [rw] max_payload_size_kb
      #   @return [Integer] Maximum job payload size in kilobytes (default: 250)
      # @!attribute [rw] enable_search_attributes
      #   @return [Boolean] Enable Temporal search attributes for job metadata (default: true)
      # @!attribute [rw] identity
      #   @return [String, nil] Optional worker identity for observability (default: nil)
      attr_accessor :target,
                    :namespace,
                    :task_queue_prefix,
                    :default_retry_backoff,
                    :default_retry_max_attempts,
                    :logger,
                    :enable_tracing,
                    :max_payload_size_kb,
                    :enable_search_attributes,
                    :identity

      # @!attribute [r] default_activity_timeout
      #   @return [ActiveSupport::Duration] Timeout for activity execution (default: 15 minutes)
      # @!attribute [r] default_retry_initial_interval
      #   @return [ActiveSupport::Duration] Initial retry interval (default: 30 seconds)
      attr_reader :default_activity_timeout, :default_retry_initial_interval

      def initialize
        @target = ENV['TEMPORAL_TARGET'] || "127.0.0.1:7233"
        @namespace = ENV['TEMPORAL_NAMESPACE'] || "default"
        @task_queue_prefix = ENV['TEMPORAL_TASK_QUEUE_PREFIX']
        self.default_activity_timeout = 15.minutes
        self.default_retry_initial_interval = 30.seconds
        @default_retry_backoff = 2.0
        @default_retry_max_attempts = 1
        @logger = default_logger
        @enable_tracing = true
        @max_payload_size_kb = (ENV['TEMPORAL_MAX_PAYLOAD_SIZE_KB']&.to_i || 250)
        @enable_search_attributes = true
        @identity = nil
      end

      # Sets the default activity timeout with validation.
      #
      # @param value [Numeric, ActiveSupport::Duration] Timeout duration
      # @raise [ArgumentError] if value is not a duration or not positive
      # @return [Numeric, ActiveSupport::Duration] the validated value
      def default_activity_timeout=(value)
        @default_activity_timeout = ensure_positive_duration!(value, :default_activity_timeout)
      end

      # Sets the default retry initial interval with validation.
      #
      # @param value [Numeric, ActiveSupport::Duration] Initial retry interval
      # @raise [ArgumentError] if value is not a duration or not positive
      # @return [Numeric, ActiveSupport::Duration] the validated value
      def default_retry_initial_interval=(value)
        @default_retry_initial_interval = ensure_positive_duration!(value, :default_retry_initial_interval)
      end

      # Validates all configuration settings.
      #
      # This method performs comprehensive validation of all configuration attributes.
      # It should be called explicitly by users after configuration to ensure all
      # settings are valid. It is NOT called automatically on config access to avoid
      # performance overhead.
      #
      # @return [void]
      # @raise [ConfigurationError] if any configuration setting is invalid
      # @example Validate configuration after setup
      #   ActiveJob::Temporal.configure do |config|
      #     config.target = "temporal.example.com:7233"
      #     config.namespace = "production"
      #   end
      #   ActiveJob::Temporal.config.validate!
      def validate!
        validate_target!
        validate_namespace!
        validate_timeouts!
        validate_retry_settings!
        validate_payload_size!
        nil
      end

      private

      def ensure_positive_duration!(value, attribute_name)
        raise ArgumentError, "#{attribute_name} must be a duration" unless value.respond_to?(:to_f)

        seconds = value.to_f
        raise ArgumentError, "#{attribute_name} must be positive" unless seconds.positive?

        value
      end

      def validate_target!
        target_regex = /^[\w.-]+:\d{1,5}$/
        return if target&.match?(target_regex)

        raise ConfigurationError,
              "target must match host:port format (e.g., 'localhost:7233'), got: #{target.inspect}"
      end

      def validate_namespace!
        namespace_regex = /^[\w-]+$/
        return if namespace&.match?(namespace_regex)

        raise ConfigurationError,
              "namespace must contain only alphanumeric characters, hyphens, and underscores, got: #{namespace.inspect}"
      end

      def validate_timeouts!
        validate_positive_duration_value!(@default_activity_timeout, "default_activity_timeout")
        validate_positive_duration_value!(@default_retry_initial_interval, "default_retry_initial_interval")
      end

      def validate_positive_duration_value!(value, attribute_name)
        # Check if it's a proper duration-like object (Numeric or ActiveSupport::Duration)
        unless value.is_a?(Numeric) || value.is_a?(ActiveSupport::Duration)
          raise ConfigurationError, "#{attribute_name} must be a duration, got: #{value.inspect}"
        end

        seconds = value.to_f
        return if seconds.positive?

        raise ConfigurationError, "#{attribute_name} must be positive, got: #{seconds}"
      end

      def validate_retry_settings!
        if default_retry_backoff < 1.0
          raise ConfigurationError,
                "default_retry_backoff must be >= 1.0, got: #{default_retry_backoff}"
        end

        return unless default_retry_max_attempts.negative?

        raise ConfigurationError,
              "default_retry_max_attempts must be >= 0, got: #{default_retry_max_attempts}"
      end

      def validate_payload_size!
        max_allowed_kb = 2_097_152 # 2 GB in KB
        if max_payload_size_kb > max_allowed_kb
          raise ConfigurationError,
                "max_payload_size_kb must be <= #{max_allowed_kb} KB (2 GB), got: #{max_payload_size_kb}"
        end

        return unless max_payload_size_kb <= 0

        raise ConfigurationError,
              "max_payload_size_kb must be positive, got: #{max_payload_size_kb}"
      end

      def default_logger
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger
        else
          ::Logger.new($stdout)
        end
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
        @config ||= Configuration.new
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
      # @raise [ActiveJob::Temporal::Error] if connection fails
      # @see Client.build
      def client
        @client ||= Client.build(config)
      end

      # Cancels a running or scheduled job by job ID.
      #
      # This method terminates the Temporal workflow associated with the job.
      # It will cancel the workflow regardless of its current state (running, scheduled, or paused).
      #
      # @param job_class [Class] the ActiveJob class (used to determine task queue)
      # @param job_id [String] the unique job identifier
      # @return [void]
      # @raise [ActiveJob::Temporal::Error] if cancellation fails
      # @example Cancel a scheduled job
      #   ActiveJob::Temporal.cancel(MyJob, "job-123-abc")
      # @see Cancel.cancel
      def cancel(job_class, job_id)
        Cancel.cancel(job_class, job_id)
      end

      # Configures the gem with a block.
      #
      # Yields the configuration object to the block for setting attributes.
      # If no block is given, returns the current configuration.
      #
      # @yield [config] Gives the configuration object to the block
      # @yieldparam config [Configuration] the configuration to modify
      # @return [Configuration] the configuration object
      # @example
      #   ActiveJob::Temporal.configure do |config|
      #     config.target = "temporal.example.com:7233"
      #     config.namespace = "production"
      #     config.default_activity_timeout = 10.minutes
      #   end
      def configure
        return config unless block_given?

        yield(config)
      end
    end
  end
end
