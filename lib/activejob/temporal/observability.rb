# frozen_string_literal: true

require "active_support/notifications"

module ActiveJob
  module Temporal
    class Error < StandardError; end unless const_defined?(:Error, false)

    module Observability
      EVENT_NAMESPACE = "activejob_temporal"
      TRACE_CONTEXT_KEY = :observability

      class Error < ActiveJob::Temporal::Error; end
      class MissingDependency < Error; end
      class UnknownAdapter < Error; end

      class << self
        def register_adapter(name, adapter_class)
          adapter_registry[name.to_sym] = adapter_class
        end

        def adapter_class(name)
          adapter_registry.fetch(name.to_sym) do
            raise UnknownAdapter, "Unknown observability adapter: #{name.inspect}"
          end
        end

        def emit(name, payload = {})
          event_payload = normalize_payload(payload)
          ActiveSupport::Notifications.instrument(event_name(name), event_payload)
          active_adapters.each { |adapter| adapter.record(name.to_sym, event_payload) }
          nil
        end

        def instrument(name, payload = {}, &)
          event_payload = normalize_payload(payload)

          ActiveSupport::Notifications.instrument(event_name(name), event_payload) do
            instrument_adapters(name.to_sym, event_payload, &)
          end
        end

        def trace_context_for_enqueue(payload = {})
          active_adapters.each_with_object({}) do |adapter, context|
            next unless adapter.respond_to?(:trace_context_for_enqueue)

            adapter_context = adapter.trace_context_for_enqueue(payload)
            context[adapter.name.to_s] = adapter_context if adapter_context && !adapter_context.empty?
          end
        end

        def inject_trace_context(payload, attributes = {})
          trace_context = trace_context_for_enqueue(attributes)
          return payload if trace_context.empty?

          observability = payload[:observability] || payload["observability"] || {}
          observability = observability.merge("trace_context" => trace_context)
          payload[:observability] = observability
          payload
        end

        def trace_context_from_payload(payload)
          observability = payload[:observability] || payload["observability"] || {}
          observability[:trace_context] || observability["trace_context"] || {}
        end

        def attributes_from_job(job, **attributes)
          normalize_payload(
            {
              job_class: job.class.name,
              job_id: job.job_id,
              queue: job.queue_name
            }.merge(attributes)
          )
        end

        def attributes_from_payload(payload, **attributes)
          normalize_payload(
            {
              job_class: payload_value(payload, :job_class),
              job_id: payload_value(payload, :job_id),
              queue: payload_value(payload, :queue_name) || payload_value(payload, :queue),
              task_queue: payload_value(payload, :activity_task_queue)
            }.merge(activity_context_attributes).merge(attributes)
          )
        end

        def retry_attempt?
          attempt = activity_context_attributes[:attempt]
          attempt && attempt.to_i > 1
        end

        def reset!
          configuration.reset!
        end

        def configuration
          ActiveJob::Temporal.config.observability
        end

        def event_name(name)
          event = name.to_s
          return event if event.end_with?(".#{EVENT_NAMESPACE}")

          "#{event}.#{EVENT_NAMESPACE}"
        end

        private

        def adapter_registry
          @adapter_registry ||= {}
        end

        def active_adapters
          return [] unless ActiveJob::Temporal.respond_to?(:config)

          configuration.adapters
        rescue StandardError
          []
        end

        def instrument_adapters(name, payload, &block)
          active_adapters.reverse.reduce(block) do |inner, adapter|
            proc { adapter.instrument(name, payload, &inner) }
          end.call
        end

        def normalize_payload(payload)
          payload.each_with_object({}) do |(key, value), normalized|
            normalized[key.to_sym] = value unless value.nil?
          end
        end

        def payload_value(payload, key)
          payload[key] || payload[key.to_s]
        end

        def activity_context_attributes
          return {} unless defined?(Temporalio::Activity::Context)
          return {} unless Temporalio::Activity::Context.exist?

          info = Temporalio::Activity::Context.current.info
          normalize_payload(
            workflow_id: context_value(info, :workflow_id),
            run_id: context_value(info, :workflow_run_id, :run_id),
            namespace: context_value(info, :workflow_namespace),
            attempt: context_value(info, :attempt)
          )
        rescue StandardError
          {}
        end

        def context_value(object, *methods)
          methods.each do |method_name|
            return object.public_send(method_name) if object.respond_to?(method_name)
          end

          nil
        end
      end

      class Configuration
        attr_reader :adapters

        def initialize
          @adapters = []
          @stop_replaced_adapters = true
        end

        def initialize_copy(original)
          super
          @adapters = original.adapters.dup
          @stop_replaced_adapters = false
        end

        def use(name, **)
          adapter = Observability.adapter_class(name).new(**)
          yield adapter if block_given?
          adapter.start!
          replace_adapter(adapter)
          adapter
        end

        def adapter(name)
          adapters.find { |registered_adapter| registered_adapter.name == name.to_sym }
        end

        def enabled?(name = nil)
          return adapters.any? unless name

          !adapter(name).nil?
        end

        def reset!
          adapters.each(&:stop!) if @stop_replaced_adapters
          adapters.clear
        end

        def validate!
          adapters.each(&:validate!)
        end

        def finalize_configuration_copy!
          @stop_replaced_adapters = true
          self
        end

        private

        def replace_adapter(adapter)
          previous_adapter = self.adapter(adapter.name)
          previous_adapter&.stop! if @stop_replaced_adapters
          adapters.delete(previous_adapter)
          adapters << adapter
        end
      end

      class Adapter
        attr_reader :name

        def initialize(name)
          @name = name.to_sym
          @started = false
        end

        def start!
          validate!
          @started = true
          self
        end

        def stop!
          @started = false
          self
        end

        def started?
          @started
        end

        def validate!
          validate_dependencies!
          self
        end

        def validate_dependencies!
          self
        end

        def record(_event_name, _payload)
          nil
        end

        def instrument(_event_name, _payload)
          yield
        end

        private

        def require_dependency(gem_name, require_path, adapter_name)
          require require_path
        rescue LoadError => e
          raise unless e.path == require_path || e.message.include?(require_path)

          raise MissingDependency,
                "#{adapter_name} observability requires the `#{gem_name}` gem. " \
                "Add `gem \"#{gem_name}\"` and require the adapter before enabling it."
        end
      end
    end
  end
end
