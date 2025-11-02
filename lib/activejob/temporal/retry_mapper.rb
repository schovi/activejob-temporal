# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require_relative "retry_handler_extractor"

module ActiveJob
  module Temporal
    # Translates ActiveJob retry DSL to Temporal RetryPolicy.
    #
    # This module introspects a job class's `retry_on` and `discard_on` declarations
    # and converts them into a Temporal-compatible retry policy hash. It handles:
    # - Retry intervals (wait durations)
    # - Retry attempt limits
    # - Non-retryable error types (from discard_on)
    #
    # The mapper uses Ruby's internal `rescue_handlers` mechanism to extract retry
    # configuration at runtime, ensuring compatibility with ActiveJob's DSL.
    #
    # @note Algorithmic Wait Values
    #   If `retry_on` uses a Proc or Symbol for `:wait` (e.g., `:exponentially_longer`),
    #   it falls back to the configured `default_retry_initial_interval` because Temporal
    #   only accepts static numeric intervals. Temporal's built-in exponential backoff
    #   (via `backoff_coefficient`) is used instead.
    #
    # @note Multiple retry_on Declarations
    #   If a job class has multiple `retry_on` declarations, the first matching handler
    #   (based on exception type) is used. Handlers are evaluated in reverse order of
    #   declaration (last declared = first matched).
    #
    # @note Exponential Backoff
    #   Temporal automatically applies exponential backoff using backoff_coefficient.
    #   For example, with initial_interval=30s and backoff_coefficient=2.0, retries occur
    #   at 30s, 60s, 120s, 240s intervals (exponentially increasing).
    #
    # @note Unlimited Retries
    #   Setting attempts: :unlimited translates to maximum_attempts: 0 in Temporal,
    #   which means the activity will retry indefinitely until it succeeds or is cancelled.
    #   Use this carefully to avoid infinite retry loops.
    #
    # @note Exception Inheritance
    #   Exception matching respects inheritance. A retry_on StandardError declaration
    #   will match all StandardError subclasses (RuntimeError, ArgumentError, etc.).
    #   More specific exceptions should be declared last to take precedence.
    #
    # @example Retry policy structure
    #   {
    #     initial_interval: 30.0,              # seconds (Float)
    #     backoff_coefficient: 2.0,            # exponential backoff multiplier
    #     maximum_attempts: 5,                 # max retry count (0 = unlimited)
    #     non_retryable_error_types: ["MyError::ClassName"]
    #   }
    #
    # @see https://docs.temporal.io/retry-policies Temporal Retry Policies
    # @see https://edgeguides.rubyonrails.org/active_job_basics.html#retrying-or-discarding-failed-jobs
    #   ActiveJob Retry Guide
    module RetryMapper
      module_function

      # Builds a Temporal retry policy hash from a job class's retry configuration.
      #
      # Inspects the job class's `retry_on` declarations and constructs a retry policy.
      # If an exception is provided, selects the matching retry handler; otherwise uses
      # the first retry handler found.
      #
      # @param job_class [Class] ActiveJob class with retry_on/discard_on declarations
      # @param exception [Exception, nil] Optional exception to match against handlers
      #
      # @return [Hash] Retry policy with keys:
      #   - :initial_interval [Float] Initial retry delay in seconds
      #   - :backoff_coefficient [Float] Exponential backoff multiplier
      #   - :maximum_attempts [Integer] Max retry attempts (0 = unlimited)
      #   - :non_retryable_error_types [Array<String>] Exception class names to not retry
      #
      # @raise [TypeError] if attempts value cannot be converted to Integer
      #
      # @example Basic retry policy
      #   class MyJob < ApplicationJob
      #     retry_on StandardError, wait: 5.seconds, attempts: 3
      #   end
      #   RetryMapper.for(MyJob)
      #   # => { initial_interval: 5.0, backoff_coefficient: 2.0, maximum_attempts: 3, ... }
      #
      # @example Unlimited retries
      #   class MyJob < ApplicationJob
      #     retry_on NetworkError, wait: 30.seconds, attempts: :unlimited
      #   end
      #   RetryMapper.for(MyJob)
      #   # => { ..., maximum_attempts: 0 }
      #
      # @example Multiple retry_on declarations (precedence)
      #   class MyJob < ApplicationJob
      #     retry_on StandardError, wait: 10.seconds, attempts: 5
      #     retry_on Timeout::Error, wait: 1.second, attempts: 10
      #   end
      #   RetryMapper.for(MyJob, Timeout::Error.new)
      #   # => { initial_interval: 1.0, maximum_attempts: 10, ... }
      #
      # @example With discard_on (non-retryable errors)
      #   class MyJob < ApplicationJob
      #     retry_on StandardError, wait: 5.seconds, attempts: 3
      #     discard_on ActiveRecord::RecordNotFound
      #   end
      #   RetryMapper.for(MyJob)
      #   # => { ..., non_retryable_error_types: ["ActiveRecord::RecordNotFound"] }
      #
      # @example Algorithmic wait (falls back to default)
      #   class MyJob < ApplicationJob
      #     retry_on NetworkError, wait: :exponentially_longer, attempts: 5
      #   end
      #   RetryMapper.for(MyJob)
      #   # => { initial_interval: 30.0, backoff_coefficient: 2.0, maximum_attempts: 5, ... }
      #   # (Uses config.default_retry_initial_interval because :exponentially_longer is not a static value)
      #
      # @note Precedence of Multiple retry_on Declarations
      #   When a job class has multiple retry_on declarations, ActiveJob's rescue_handlers
      #   are evaluated in reverse order (last declared = first matched). If you provide an
      #   exception argument, the first matching handler is used. Without an exception, the
      #   first handler in the list is used.
      def for(job_class, exception = nil)
        config = ActiveJob::Temporal.config
        retry_entry = select_retry_entry(job_class, exception)

        {
          initial_interval: interval_from(retry_entry&.fetch(:wait, nil), config),
          backoff_coefficient: config.default_retry_backoff,
          maximum_attempts: attempts_from(retry_entry&.fetch(:attempts, nil), config),
          non_retryable_error_types: discard_exception_names(job_class)
        }
      end

      # Checks if an exception should be discarded (not retried).
      #
      # Inspects the job class's `discard_on` declarations to determine if the given
      # exception matches any discard handler. If true, the activity should raise
      # a non-retryable error to stop Temporal from retrying.
      #
      # @param job_class [Class] ActiveJob class with discard_on declarations
      # @param exception [Exception] Exception instance to check
      #
      # @return [Boolean] true if exception should be discarded, false otherwise
      #
      # @example Check if exception is discardable
      #   class MyJob < ApplicationJob
      #     discard_on ActiveRecord::RecordNotFound
      #   end
      #   RetryMapper.discard_exception?(MyJob, ActiveRecord::RecordNotFound.new)
      #   # => true
      def discard_exception?(job_class, exception)
        extractor.discard_exception?(job_class, exception)
      end

      # -- helpers ----------------------------------------------------------------

      # Returns the handler extractor instance (memoized).
      # @api private
      def extractor
        @extractor ||= RetryHandlerExtractor.new
      end
      private_class_method :extractor

      # Selects the matching retry handler entry for the given exception.
      # @api private
      def select_retry_entry(job_class, exception)
        handlers = extractor.retry_handlers(job_class)
        return nil if handlers.empty?

        return handlers.find { |handler| handles_exception?(handler[:exception], exception) } if exception

        handlers.first
      end
      private_class_method :select_retry_entry

      # Extracts discard handler exception class names.
      # @api private
      def discard_exception_names(job_class)
        extractor.discard_handlers(job_class).each_with_object([]) do |handler, names|
          next unless handler[:exception]

          name = handler[:exception].name
          next unless name
          next if names.include?(name)

          names << name
        end
      end
      private_class_method :discard_exception_names

      # Extracts initial interval from retry_on wait value.
      # @api private
      def interval_from(value, config)
        # Temporal only accepts numeric intervals, so algorithmic waits (Proc/Symbol)
        # fall back to the configured default for now.
        case value
        when Numeric, ActiveSupport::Duration
          value.to_f
        else
          config.default_retry_initial_interval.to_f
        end
      end
      private_class_method :interval_from

      # Extracts maximum attempts from retry_on attempts value.
      # @api private
      def attempts_from(value, config)
        case value
        when nil
          config.default_retry_max_attempts
        when :unlimited
          0
        else
          Integer(value)
        end
      rescue ArgumentError, TypeError
        config.default_retry_max_attempts
      end
      private_class_method :attempts_from

      # Checks if handler_class handles the given exception.
      # Delegates to the extractor's private method via duck typing.
      # @api private
      def handles_exception?(handler_class, exception)
        return false unless handler_class && exception

        candidate_class = exception.is_a?(Module) ? exception : exception.class
        candidate_class <= handler_class
      end
      private_class_method :handles_exception?
    end
  end
end
