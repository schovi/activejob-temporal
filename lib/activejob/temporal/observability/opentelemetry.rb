# frozen_string_literal: true

require_relative "../observability"
require_relative "../version"

module ActiveJob
  module Temporal
    module Observability
      class OpenTelemetry < Adapter
        SPAN_EVENTS = %i[enqueue perform retry].freeze

        attr_writer :tracer, :propagation

        def initialize(tracer: nil, propagation: nil)
          super(:opentelemetry)
          @tracer = tracer
          @propagation = propagation
        end

        def trace_context_for_enqueue(_payload)
          carrier = {}
          propagation.inject(carrier)
          carrier
        end

        def record(event_name, payload)
          return unless event_name == :enqueue

          trace(:enqueue, payload) { nil }
        end

        def instrument(event_name, payload, &block)
          return block.call unless SPAN_EVENTS.include?(event_name)

          trace(event_name, payload, &block)
        end

        def validate_dependencies!
          require_dependency("opentelemetry-sdk", "opentelemetry/sdk", "OpenTelemetry")
          self
        end

        private

        def trace(event_name, payload, &)
          context = extracted_context(payload)
          if context
            ::OpenTelemetry::Context.with_current(context) do
              trace_span(event_name, payload, &)
            end
          else
            trace_span(event_name, payload, &)
          end
        end

        def trace_span(event_name, payload)
          tracer.in_span(span_name(event_name), attributes: span_attributes(payload)) do |span|
            yield
          rescue StandardError => e
            span.record_exception(e) if span.respond_to?(:record_exception)
            raise
          end
        end

        def extracted_context(payload)
          carrier = Observability.trace_context_from_payload(payload).fetch("opentelemetry", nil)
          return if carrier.nil? || carrier.empty?

          propagation.extract(carrier)
        end

        def tracer
          @tracer ||= ::OpenTelemetry.tracer_provider.tracer(
            "activejob-temporal",
            ActiveJob::Temporal::VERSION
          )
        end

        def propagation
          @propagation ||= ::OpenTelemetry.propagation
        end

        def span_name(event_name)
          "activejob_temporal.#{event_name}"
        end

        def span_attributes(payload)
          {
            "activejob_temporal.job_class" => payload[:job_class],
            "activejob_temporal.job_id" => payload[:job_id],
            "activejob_temporal.queue" => payload[:queue],
            "activejob_temporal.workflow_id" => payload[:workflow_id],
            "activejob_temporal.run_id" => payload[:run_id],
            "activejob_temporal.namespace" => payload[:namespace],
            "activejob_temporal.task_queue" => payload[:task_queue],
            "activejob_temporal.attempt" => payload[:attempt]
          }.compact
        end
      end
    end
  end
end

ActiveJob::Temporal::Observability.register_adapter(
  :opentelemetry,
  ActiveJob::Temporal::Observability::OpenTelemetry
)
