# frozen_string_literal: true

require_relative "../observability"

module ActiveJob
  module Temporal
    module Observability
      # rubocop:disable Metrics/ClassLength
      class Datadog < Adapter
        attr_accessor :service, :statsd_host, :statsd_port
        attr_writer :statsd

        def initialize(service: "activejob-temporal", statsd: nil, statsd_host: "127.0.0.1", statsd_port: 8125)
          super(:datadog)
          @service = service
          @statsd = statsd
          @statsd_host = statsd_host
          @statsd_port = statsd_port
        end

        def trace_context_for_enqueue(_payload)
          trace = ::Datadog::Tracing.active_trace if defined?(::Datadog::Tracing)
          return {} unless trace.respond_to?(:to_digest)

          carrier = {}
          ::Datadog::Tracing::Contrib::HTTP.inject(trace.to_digest, carrier)
          carrier
        end

        def record(event_name, payload)
          case event_name
          when :enqueue then record_enqueue(payload)
          when :payload_serialize then record_payload_size(payload)
          when :retry then record_retry(payload)
          when :worker_start then record_worker_started(payload)
          when :worker_stop then record_worker_stopped(payload)
          when :active_tasks then record_active_tasks(payload)
          end
        end

        def instrument(event_name, payload)
          return yield unless event_name == :perform

          started_at = monotonic_time
          trace(event_name, payload) do
            result = yield
            statsd.increment("activejob_temporal.jobs.completed", tags: tags(payload))
            result
          rescue StandardError => e
            statsd.increment("activejob_temporal.jobs.failed", tags: tags(payload, error: e.class.name))
            raise
          ensure
            statsd.histogram(
              "activejob_temporal.job_duration.seconds",
              monotonic_time - started_at,
              tags: tags(payload)
            )
          end
        end

        def validate_dependencies!
          require_dependency("datadog", "datadog", "Datadog")
          require_dependency("datadog", "datadog/statsd", "Datadog")
          require_dependency("datadog", "datadog/tracing/contrib/http", "Datadog")
          self
        end

        private

        def record_enqueue(payload)
          trace(:enqueue, payload) do
            statsd.increment("activejob_temporal.jobs.enqueued", tags: tags(payload))
          end
        end

        def record_payload_size(payload)
          statsd.histogram("activejob_temporal.payload_size.bytes", payload[:bytes], tags: tags(payload))
        end

        def record_retry(payload)
          statsd.increment("activejob_temporal.retries", tags: tags(payload, error: payload[:error]))
        end

        def record_worker_started(payload)
          statsd.gauge("activejob_temporal.active_workers", 1, tags: worker_tags(payload))
        end

        def record_worker_stopped(payload)
          statsd.gauge("activejob_temporal.active_workers", 0, tags: worker_tags(payload))
          statsd.gauge("activejob_temporal.active_tasks", 0, tags: worker_tags(payload))
        end

        def record_active_tasks(payload)
          statsd.gauge("activejob_temporal.active_tasks", payload[:count].to_i, tags: worker_tags(payload))
        end

        def trace(event_name, payload)
          digest = extracted_digest(payload)
          options = {
            service: service,
            resource: payload[:job_class]
          }.compact
          options[:continue_from] = digest if digest

          ::Datadog::Tracing.trace("activejob_temporal.#{event_name}", **options) do |span|
            set_span_tags(span, payload)
            yield
          end
        end

        def extracted_digest(payload)
          carrier = Observability.trace_context_from_payload(payload).fetch("datadog", nil)
          return if carrier.nil? || carrier.empty?

          ::Datadog::Tracing::Contrib::HTTP.extract(carrier)
        end

        def set_span_tags(span, payload)
          span.set_tag("activejob_temporal.job_class", payload[:job_class])
          span.set_tag("activejob_temporal.job_id", payload[:job_id])
          span.set_tag("activejob_temporal.queue", payload[:queue])
          span.set_tag("activejob_temporal.workflow_id", payload[:workflow_id])
          span.set_tag("activejob_temporal.run_id", payload[:run_id])
          span.set_tag("activejob_temporal.namespace", payload[:namespace])
          span.set_tag("activejob_temporal.task_queue", payload[:task_queue])
          span.set_tag("activejob_temporal.attempt", payload[:attempt])
        end

        def statsd
          @statsd ||= ::Datadog::Statsd.new(statsd_host, statsd_port)
        end

        def tags(payload, error: nil)
          [
            tag("job_class", payload[:job_class]),
            tag("queue", payload[:queue]),
            tag("namespace", payload[:namespace]),
            tag("task_queue", payload[:task_queue]),
            tag("error", error)
          ].compact
        end

        def worker_tags(payload)
          [
            tag("namespace", payload[:namespace]),
            tag("task_queue", payload[:task_queue]),
            tag("worker_id", payload[:worker_id])
          ].compact
        end

        def tag(name, value)
          "#{name}:#{value}" unless value.nil?
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end

ActiveJob::Temporal::Observability.register_adapter(
  :datadog,
  ActiveJob::Temporal::Observability::Datadog
)
