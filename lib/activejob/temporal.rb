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
require_relative "temporal/cancel"

module ActiveJob
  module Temporal
    class Error < StandardError; end

    class Configuration
      attr_accessor :target,
                    :namespace,
                    :task_queue_prefix,
                    :default_retry_backoff,
                    :default_retry_max_attempts,
                    :logger,
                    :enable_tracing,
                    :max_payload_size_kb

      attr_reader :default_activity_timeout, :default_retry_initial_interval

      def initialize
        @target = "127.0.0.1:7233"
        @namespace = "default"
        @task_queue_prefix = nil
        self.default_activity_timeout = 15.minutes
        self.default_retry_initial_interval = 30.seconds
        @default_retry_backoff = 2.0
        @default_retry_max_attempts = 1
        @logger = default_logger
        @enable_tracing = true
        @max_payload_size_kb = 250
      end

      def default_activity_timeout=(value)
        @default_activity_timeout = ensure_positive_duration!(value, :default_activity_timeout)
      end

      def default_retry_initial_interval=(value)
        @default_retry_initial_interval = ensure_positive_duration!(value, :default_retry_initial_interval)
      end

      private

      def ensure_positive_duration!(value, attribute_name)
        raise ArgumentError, "#{attribute_name} must be a duration" unless value.respond_to?(:to_f)

        seconds = value.to_f
        raise ArgumentError, "#{attribute_name} must be positive" unless seconds.positive?

        value
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
      def config
        @config ||= Configuration.new
      end
      alias configuration config

      # Returns the memoized Temporal client connection for the process.
      # TLS options can be provided via configuration or ENV variables (see Client module).
      def client
        @client ||= Client.build(config)
      end

      def cancel(job_class, job_id)
        Cancel.cancel(job_class, job_id)
      end

      def configure
        return config unless block_given?

        yield(config)
      end
    end
  end
end
