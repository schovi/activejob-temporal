# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module ActiveJob
  module Temporal
    # Extracts ActiveJob retry_on and discard_on handler declarations.
    #
    # This class introspects an ActiveJob class to find all retry_on and
    # discard_on declarations, converting them into structured handler objects.
    # It handles the complexity of ActiveJob's internal rescue_handlers mechanism,
    # including binding inspection and exception class constantization.
    #
    # The extractor is used by RetryMapper to separate handler extraction logic
    # from retry policy building logic, improving testability and maintainability.
    #
    # @example Extracting retry handlers
    #   extractor = RetryHandlerExtractor.new
    #   retry_handlers = extractor.retry_handlers(MyJob)
    #   # => [{ exception: StandardError, wait: 5.seconds, attempts: 3, handler: ... }]
    #
    # @example Extracting discard handlers
    #   discard_handlers = extractor.discard_handlers(MyJob)
    #   # => [{ exception: ActiveRecord::RecordNotFound, handler: ... }]
    class RetryHandlerExtractor
      # Extracts retry handler entries from a job class's rescue_handlers.
      #
      # Iterates through the job class's rescue_handlers and filters for retry_on
      # declarations (identified by the presence of an :attempts local variable in
      # the handler's binding). Returns structured handler entries with exception
      # class, wait strategy, and attempt limit.
      #
      # @param job_class [Class] ActiveJob class with retry_on declarations
      #
      # @return [Array<Hash>] Array of retry handler entries, each containing:
      #   - :exception [Class] Exception class to match
      #   - :wait [Numeric, Symbol, Proc] Wait strategy (duration, :exponentially_longer, etc.)
      #   - :attempts [Integer, Symbol] Max attempts (number or :unlimited)
      #   - :handler [Proc] The raw handler proc from ActiveJob
      #
      # @example Basic retry handler
      #   class MyJob < ActiveJob::Base
      #     retry_on StandardError, wait: 5.seconds, attempts: 3
      #   end
      #
      #   extractor = RetryHandlerExtractor.new
      #   handlers = extractor.retry_handlers(MyJob)
      #   # => [{ exception: StandardError, wait: 5.0, attempts: 3, handler: #<Proc> }]
      def retry_handlers(job_class)
        handler_entries(job_class) do |handler|
          next unless handler.respond_to?(:binding)

          binding = handler.binding
          next unless retry_handler_binding?(binding)

          {
            handler: handler,
            wait: binding.local_variable_get(:wait),
            attempts: binding.local_variable_get(:attempts)
          }
        end
      end

      # Extracts discard handler entries from a job class's rescue_handlers.
      #
      # Iterates through the job class's rescue_handlers and filters for discard_on
      # declarations (identified by the presence of :report but absence of :attempts
      # in the handler's binding). Returns structured handler entries with exception
      # classes that should not be retried.
      #
      # @param job_class [Class] ActiveJob class with discard_on declarations
      #
      # @return [Array<Hash>] Array of discard handler entries, each containing:
      #   - :exception [Class] Exception class to discard (not retry)
      #   - :handler [Proc] The raw handler proc from ActiveJob
      #
      # @example Basic discard handler
      #   class MyJob < ActiveJob::Base
      #     discard_on ActiveRecord::RecordNotFound
      #   end
      #
      #   extractor = RetryHandlerExtractor.new
      #   handlers = extractor.discard_handlers(MyJob)
      #   # => [{ exception: ActiveRecord::RecordNotFound, handler: #<Proc> }]
      def discard_handlers(job_class)
        handler_entries(job_class) do |handler|
          next unless handler.respond_to?(:binding)

          binding = handler.binding
          next unless discard_handler_binding?(binding)

          { handler: handler }
        end
      end

      # Checks if an exception should be discarded based on job class handlers.
      #
      # Inspects the job class's discard_on declarations to determine if the given
      # exception matches any discard handler. This is used to determine if an
      # activity should raise a non-retryable error in Temporal.
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
      #
      #   extractor = RetryHandlerExtractor.new
      #   extractor.discard_exception?(MyJob, ActiveRecord::RecordNotFound.new)
      #   # => true
      def discard_exception?(job_class, exception)
        return false unless job_class && exception

        discard_handlers(job_class).any? do |handler|
          handles_exception?(handler[:exception], exception)
        end
      end

      private

      # Generic handler entry extractor (used by retry_handlers and discard_handlers).
      #
      # Walks through the job class's rescue_handlers in reverse order (ActiveJob's
      # precedence order: last declared = first matched) and yields each handler to
      # the provided block for filtering and transformation.
      #
      # @api private
      # @param job_class [Class] ActiveJob class
      # @yield [handler] Block that filters and transforms each handler
      # @return [Array<Hash>] Filtered and transformed handler entries
      def handler_entries(job_class)
        return [] unless job_class
        return [] unless job_class.respond_to?(:rescue_handlers)

        handlers = job_class.rescue_handlers
        return [] unless handlers.respond_to?(:reverse_each)

        entries = []
        handlers.reverse_each do |class_or_name, handler|
          payload = yield(handler)
          next unless payload

          exception_class = constantize_handler_class(job_class, class_or_name)
          next unless exception_class

          entries << payload.merge(exception: exception_class)
        end
        entries
      end

      # Checks if a binding represents a retry handler.
      #
      # Retry handlers are identified by the presence of an :attempts local variable
      # in the handler proc's binding. This is how ActiveJob internally stores
      # retry_on declarations.
      #
      # @api private
      # @param binding [Binding] Handler proc's binding
      # @return [Boolean] true if binding represents a retry handler
      def retry_handler_binding?(binding)
        binding&.local_variable_defined?(:attempts)
      end

      # Checks if a binding represents a discard handler.
      #
      # Discard handlers are identified by the presence of :report but absence of
      # :attempts in the handler proc's binding. This is how ActiveJob internally
      # stores discard_on declarations.
      #
      # @api private
      # @param binding [Binding] Handler proc's binding
      # @return [Boolean] true if binding represents a discard handler
      def discard_handler_binding?(binding)
        binding&.local_variable_defined?(:report) && !binding.local_variable_defined?(:attempts)
      end

      # Constantizes exception class from symbol/string/module.
      #
      # ActiveJob stores exception handlers with various types (Module, String, Symbol).
      # This method normalizes them to actual exception classes, handling both
      # relative constants (defined in job class) and global constants.
      #
      # @api private
      # @param job_class [Class] Job class for relative constant lookup
      # @param class_or_name [Module, String, Symbol] Exception class or name
      # @return [Class, nil] Constantized exception class, or nil if not found
      def constantize_handler_class(job_class, class_or_name)
        case class_or_name
        when Module
          class_or_name
        when String, Symbol
          job_class.const_get(class_or_name)
        end
      rescue NameError
        class_or_name.to_s.safe_constantize
      end

      # Checks if handler_class handles the given exception.
      #
      # Uses Ruby's inheritance mechanism to check if the exception is an instance
      # of (or subclass of) the handler's exception class. Supports both exception
      # instances and exception classes.
      #
      # @api private
      # @param handler_class [Class] Exception class from handler
      # @param exception [Exception, Class] Exception to check
      # @return [Boolean] true if handler_class handles the exception
      def handles_exception?(handler_class, exception)
        return false unless handler_class && exception

        candidate_class = exception.is_a?(Module) ? exception : exception.class
        candidate_class <= handler_class
      end
    end
  end
end
