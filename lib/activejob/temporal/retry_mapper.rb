# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module ActiveJob
  module Temporal
    module RetryMapper
      module_function

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

      def discard_exception?(job_class, exception)
        return false unless job_class && exception

        discard_handlers(job_class).any? do |handler|
          handles_exception?(handler[:exception], exception)
        end
      end

      # -- helpers ----------------------------------------------------------------

      def select_retry_entry(job_class, exception)
        handlers = retry_handlers(job_class)
        return nil if handlers.empty?

        return handlers.find { |handler| handles_exception?(handler[:exception], exception) } if exception

        handlers.first
      end
      private_class_method :select_retry_entry

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
      private_class_method :retry_handlers

      def discard_handlers(job_class)
        handler_entries(job_class) do |handler|
          next unless handler.respond_to?(:binding)

          binding = handler.binding
          next unless discard_handler_binding?(binding)

          { handler: handler }
        end
      end
      private_class_method :discard_handlers

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
      private_class_method :handler_entries

      def retry_handler_binding?(binding)
        binding&.local_variable_defined?(:attempts)
      end
      private_class_method :retry_handler_binding?

      def discard_handler_binding?(binding)
        binding&.local_variable_defined?(:report) && !binding.local_variable_defined?(:attempts)
      end
      private_class_method :discard_handler_binding?

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
      private_class_method :constantize_handler_class

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

      def discard_exception_names(job_class)
        discard_handlers(job_class).each_with_object([]) do |handler, names|
          next unless handler[:exception]

          name = handler[:exception].name
          next unless name
          next if names.include?(name)

          names << name
        end
      end
      private_class_method :discard_exception_names

      def handles_exception?(handler_class, exception)
        return false unless handler_class && exception

        candidate_class = exception.is_a?(Module) ? exception : exception.class
        candidate_class <= handler_class
      end
      private_class_method :handles_exception?
    end
  end
end
