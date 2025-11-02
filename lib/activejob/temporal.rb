# frozen_string_literal: true

require "logger"
require "active_support/core_ext/numeric/time"

require_relative "temporal/version"
require_relative "temporal/client"
require_relative "temporal/logger"
require_relative "temporal/payload"
require_relative "temporal/search_attributes"
require_relative "temporal/retry_mapper"
require_relative "temporal/workflow_enqueuer"
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
    # Use {ActiveJob::Temporal.configure} to set configuration values.
    #
    # @note Thread Safety
    #   The configuration object is NOT thread-safe for modification. All configuration
    #   changes should be completed during application initialization before workers start.
    #   Reading configuration is thread-safe.
    #
    # @note Environment Variable Defaults
    #   Several configuration values can be set via environment variables:
    #   TEMPORAL_TARGET, TEMPORAL_NAMESPACE, TEMPORAL_TASK_QUEUE_PREFIX,
    #   TEMPORAL_MAX_PAYLOAD_SIZE_KB, TEMPORAL_MAX_CONCURRENT_ACTIVITIES,
    #   TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS, TEMPORAL_TLS_CERT, TEMPORAL_TLS_KEY,
    #   TEMPORAL_TLS_SERVER_NAME. Configuration attributes take precedence over env vars.
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
      # @!attribute [rw] max_concurrent_activities
      #   @return [Integer] Maximum number of activities that can execute concurrently per worker process (default: 100)
      # @!attribute [rw] max_concurrent_workflow_tasks
      #   @return [Integer] Maximum workflow tasks concurrently per worker process (default: 100)
      attr_accessor :target,
                    :namespace,
                    :task_queue_prefix,
                    :default_retry_backoff,
                    :default_retry_max_attempts,
                    :logger,
                    :enable_tracing,
                    :max_payload_size_kb,
                    :enable_search_attributes,
                    :identity,
                    :max_concurrent_activities,
                    :max_concurrent_workflow_tasks

      # @!attribute [r] default_activity_timeout
      #   @return [ActiveSupport::Duration] Timeout for activity execution (default: 15 minutes)
      # @!attribute [r] default_retry_initial_interval
      #   @return [ActiveSupport::Duration] Initial retry interval (default: 30 seconds)
      attr_reader :default_activity_timeout, :default_retry_initial_interval

      def initialize
        @target = ENV["TEMPORAL_TARGET"] || "127.0.0.1:7233"
        @namespace = ENV["TEMPORAL_NAMESPACE"] || "default"
        @task_queue_prefix = ENV.fetch("TEMPORAL_TASK_QUEUE_PREFIX", nil)
        self.default_activity_timeout = 15.minutes
        self.default_retry_initial_interval = 30.seconds
        @default_retry_backoff = 2.0
        @default_retry_max_attempts = 1
        @logger = default_logger
        @enable_tracing = true
        @max_payload_size_kb = ENV["TEMPORAL_MAX_PAYLOAD_SIZE_KB"]&.to_i || 250
        @enable_search_attributes = true
        @identity = nil
        @max_concurrent_activities = ENV["TEMPORAL_MAX_CONCURRENT_ACTIVITIES"]&.to_i || 100
        @max_concurrent_workflow_tasks = ENV["TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS"]&.to_i || 100
      end

      # Sets the default activity timeout with validation.
      #
      # @param value [Numeric, ActiveSupport::Duration] Timeout duration
      # @raise [ArgumentError] if value is not a duration
      # @raise [ArgumentError] if value is not positive
      # @return [Numeric, ActiveSupport::Duration] the validated value
      def default_activity_timeout=(value)
        @default_activity_timeout = ensure_positive_duration!(value, :default_activity_timeout)
      end

      # Sets the default retry initial interval with validation.
      #
      # @param value [Numeric, ActiveSupport::Duration] Initial retry interval
      # @raise [ArgumentError] if value is not a duration
      # @raise [ArgumentError] if value is not positive
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
      # @raise [ConfigurationError] if target is not in host:port format
      # @raise [ConfigurationError] if namespace contains invalid characters
      # @raise [ConfigurationError] if default_activity_timeout is not positive
      # @raise [ConfigurationError] if default_retry_initial_interval is not positive
      # @raise [ConfigurationError] if default_retry_backoff is less than 1.0
      # @raise [ConfigurationError] if default_retry_max_attempts is negative
      # @raise [ConfigurationError] if max_payload_size_kb exceeds 2GB limit
      # @raise [ConfigurationError] if max_payload_size_kb is not positive
      # @raise [ConfigurationError] if max_concurrent_activities is not positive
      # @raise [ConfigurationError] if max_concurrent_workflow_tasks is not positive
      # @example Validate configuration after setup
      #   ActiveJob::Temporal.configure do |config|
      #     config.target = "temporal.example.com:7233"
      #     config.namespace = "production"
      #   end
      #   ActiveJob::Temporal.config.validate!
      #
      # @example Handling validation errors
      #   begin
      #     ActiveJob::Temporal.config.target = "invalid-format"
      #     ActiveJob::Temporal.config.validate!
      #   rescue ActiveJob::Temporal::ConfigurationError => e
      #     puts "Configuration invalid: #{e.message}"
      #     # => "target must match host:port format..."
      #   end
      def validate!
        errors = []
        errors.concat(validate_target_errors)
        errors.concat(validate_namespace_errors)
        errors.concat(validate_timeouts_errors)
        errors.concat(validate_retry_settings_errors)
        errors.concat(validate_payload_size_errors)
        errors.concat(validate_worker_concurrency_errors)

        raise ConfigurationError, format_validation_errors(errors) unless errors.empty?

        nil
      end

      private

      # Ensures a value is a positive duration.
      # @api private
      def ensure_positive_duration!(value, attribute_name)
        raise ArgumentError, "#{attribute_name} must be a duration" unless value.respond_to?(:to_f)

        seconds = value.to_f
        raise ArgumentError, "#{attribute_name} must be positive" unless seconds.positive?

        value
      end

      # Collects target validation errors.
      # @api private
      # @return [Array<String>] list of validation errors
      def validate_target_errors
        errors = []

        if target.nil? || target.empty?
          errors << "Target host is required (set TEMPORAL_TARGET or config.target)"
        else
          target_regex = /^[\w.-]+:\d{1,5}$/
          unless target.match?(target_regex)
            errors << "Target must be in format 'host:port' " \
                      "(e.g., 'localhost:7233' or 'temporal.example.com:7233'), got: #{target.inspect}"
          end
        end

        errors
      end

      # Collects namespace validation errors.
      # @api private
      # @return [Array<String>] list of validation errors
      def validate_namespace_errors
        errors = []

        if namespace.nil? || namespace.empty?
          errors << "Namespace is required (set TEMPORAL_NAMESPACE or config.namespace)"
        else
          namespace_regex = /^[\w-]+$/
          unless namespace.match?(namespace_regex)
            errors << "Namespace must contain only alphanumeric characters, hyphens, and underscores " \
                      "(got: #{namespace.inspect}). Use 'prod-default' not 'prod_default!'"
          end
        end

        errors
      end

      # Collects timeout validation errors.
      # @api private
      # @return [Array<String>] list of validation errors
      def validate_timeouts_errors
        errors = []
        errors.concat(validate_positive_duration_value(@default_activity_timeout, "default_activity_timeout"))
        errors.concat(validate_positive_duration_value(@default_retry_initial_interval,
                                                       "default_retry_initial_interval"))
        errors
      end

      # Validates that a value is a positive duration.
      # @api private
      # @return [Array<String>] list of validation errors
      def validate_positive_duration_value(value, attribute_name)
        errors = []

        # Check if it's a proper duration-like object (Numeric or ActiveSupport::Duration)
        unless value.is_a?(Numeric) || value.is_a?(ActiveSupport::Duration)
          errors << "#{attribute_name} must be a duration (e.g., 10.minutes or 30.seconds), got: #{value.inspect}"
          return errors
        end

        seconds = value.to_f
        unless seconds.positive?
          errors << "#{attribute_name} must be positive (got: #{seconds} seconds). " \
                    "Use values like 1.second or 10.minutes"
        end

        errors
      end

      # Collects retry settings validation errors.
      # @api private
      # @return [Array<String>] list of validation errors
      def validate_retry_settings_errors
        errors = []

        if default_retry_backoff < 1.0
          errors << "default_retry_backoff must be >= 1.0 (got: #{default_retry_backoff}). " \
                    "Use 2.0 for exponential backoff"
        end

        if default_retry_max_attempts.negative?
          errors << "default_retry_max_attempts must be >= 0 (got: #{default_retry_max_attempts}). " \
                    "Use 0 for unlimited retries, or positive number for max attempts"
        end

        errors
      end

      # Collects payload size validation errors.
      # @api private
      # @return [Array<String>] list of validation errors
      def validate_payload_size_errors
        errors = []
        max_allowed_kb = 2_097_152 # 2 GB in KB

        if max_payload_size_kb <= 0
          errors << "max_payload_size_kb must be positive (got: #{max_payload_size_kb}). " \
                    "Typical values: 250 KB (default), 500 KB (large), or 1000 KB (very large)"
        elsif max_payload_size_kb > max_allowed_kb
          errors << "max_payload_size_kb cannot exceed #{max_allowed_kb} KB (2 GB) " \
                    "per Temporal limits (got: #{max_payload_size_kb})"
        end

        errors
      end

      # Collects worker concurrency validation errors.
      # @api private
      # @return [Array<String>] list of validation errors
      def validate_worker_concurrency_errors
        errors = []

        if max_concurrent_activities <= 0
          errors << "max_concurrent_activities must be positive (got: #{max_concurrent_activities}). " \
                    "Typical values: 50 (low), 100 (default), 200+ (high throughput)"
        end

        if max_concurrent_workflow_tasks <= 0
          errors << "max_concurrent_workflow_tasks must be positive (got: #{max_concurrent_workflow_tasks}). " \
                    "Typical values: 5 (default), 10-50 (medium), 100+ (high throughput)"
        end

        errors
      end

      # Formats validation errors for display.
      # @api private
      # @param errors [Array<String>] list of error messages
      # @return [String] formatted error message
      def format_validation_errors(errors)
        return errors.first if errors.size == 1

        error_list = errors.each_with_index.map do |error, i|
          "  #{i + 1}. #{error}"
        end.join("\n")

        "Configuration validation failed with #{errors.size} error#{'s' if errors.size > 1}:\n#{error_list}"
      end

      # Returns default logger (Rails.logger or stdout).
      # @api private
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

      # Configures the gem with a block.
      #
      # Yields the configuration object to the block for setting attributes.
      # If no block is given, returns the current configuration.
      #
      # @yield [config] Gives the configuration object to the block
      # @yieldparam config [Configuration] the configuration to modify
      # @return [Configuration] the configuration object
      # @example Basic configuration
      #   ActiveJob::Temporal.configure do |config|
      #     config.target = "temporal.example.com:7233"
      #     config.namespace = "production"
      #     config.default_activity_timeout = 10.minutes
      #   end
      #
      # @example Configuration with TLS
      #   ActiveJob::Temporal.configure do |config|
      #     config.target = "temporal.example.com:7233"
      #     config.namespace = "production"
      #     config.tls = {
      #       certificate: File.read("client.pem"),
      #       private_key: File.read("client-key.pem"),
      #       server_name: "temporal.example.com"
      #     }
      #   end
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

        yield(config)
      end
    end
  end
end
