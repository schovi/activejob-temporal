# frozen_string_literal: true

require_relative "../metrics_server"
require_relative "../observability"

module ActiveJob
  module Temporal
    module Observability
      class MetricsServerConfiguration
        attr_accessor :port, :bind, :allow_public_bind

        def initialize
          @port = nil
          @bind = MetricsServer::DEFAULT_BIND_ADDRESS
          @allow_public_bind = false
        end
      end

      module PrometheusErrorLabels
        LABEL_CLASSES = [
          ActiveJob::DeserializationError,
          ActiveJob::SerializationError,
          NoMethodError,
          NameError,
          ArgumentError,
          TypeError,
          LoadError,
          SystemCallError,
          IOError,
          RuntimeError,
          StandardError,
          ScriptError,
          Exception
        ].freeze

        module_function

        def for(error)
          error_class = error_class_for(error)
          label_class = LABEL_CLASSES.find { |klass| error_class <= klass }

          (label_class&.name || "Unknown").to_s
        end

        def error_class_for(error)
          return error if error.is_a?(Class)
          return error.class if error.is_a?(Exception)

          LABEL_CLASSES.find { |klass| klass.name == error.to_s } || StandardError
        end
      end

      # rubocop:disable Metrics/ClassLength
      class Prometheus < Adapter
        DURATION_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120].freeze
        PAYLOAD_SIZE_BUCKETS = [512, 1024, 2_048, 4_096, 8_192, 16_384, 32_768, 65_536, 131_072, 262_144,
                                524_288, 1_048_576].freeze

        attr_reader :registry, :metrics_server

        def initialize(registry: nil, monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          super(:prometheus)
          @registry = registry
          @monotonic_clock = monotonic_clock
          @metrics_server = MetricsServerConfiguration.new
          @server = nil
          @registered = false
        end

        def start!
          super
          ensure_metrics_registered
          self
        end

        def stop!
          stop_metrics_server
          super
        end

        def record(event_name, payload)
          ensure_metrics_registered

          case event_name
          when :enqueue then record_enqueue(payload)
          when :payload_serialize then observe_payload_size(payload)
          when :retry then record_retry(payload)
          when :worker_start then record_worker_started
          when :worker_stop then record_worker_stopped
          when :active_tasks then record_active_tasks(payload[:count])
          end
        end

        def instrument(event_name, payload)
          return yield unless event_name == :perform

          ensure_metrics_registered
          started_at = monotonic_time

          result = yield
          @jobs_completed.increment(labels: { class: label(payload[:job_class]), queue: label(payload[:queue]) })
          result
        rescue StandardError => e
          @jobs_failed.increment(labels: {
                                   class: label(payload[:job_class]),
                                   queue: label(payload[:queue]),
                                   error: PrometheusErrorLabels.for(e)
                                 })
          raise
        ensure
          if started_at
            @job_duration.observe(monotonic_time - started_at, labels: { class: label(payload[:job_class]) })
          end
        end

        def render
          ensure_metrics_registered
          ::Prometheus::Client::Formats::Text.marshal(registry)
        end

        def start_metrics_server(port: metrics_server.port,
                                 bind_address: metrics_server.bind,
                                 allow_public_bind: metrics_server.allow_public_bind)
          raise ArgumentError, "Prometheus metrics server port is required" unless port

          @server = MetricsServer.new(
            port: port,
            bind_address: bind_address,
            allow_public_bind: allow_public_bind,
            provider: self
          ).start
        end

        def stop_metrics_server
          @server&.stop
          @server = nil
        end

        def validate_dependencies!
          require_dependency("prometheus-client", "prometheus/client", "Prometheus")
          require_dependency("prometheus-client", "prometheus/client/formats/text", "Prometheus")
          @registry ||= ::Prometheus::Client::Registry.new
          self
        end

        private

        def record_enqueue(payload)
          return if payload[:duplicate]

          @jobs_enqueued.increment(labels: { class: label(payload[:job_class]), queue: label(payload[:queue]) })
        end

        def observe_payload_size(payload)
          @payload_size.observe(payload[:bytes], labels: { class: label(payload[:job_class]) })
        end

        def record_retry(payload)
          @retries.increment(labels: {
                               class: label(payload[:job_class]),
                               error: PrometheusErrorLabels.for(payload[:error])
                             })
        end

        def record_worker_started
          @active_workers.set(1)
        end

        def record_worker_stopped
          @active_workers.set(0)
          record_active_tasks(0)
        end

        def record_active_tasks(count)
          @active_tasks.set(count.to_i)
        end

        def ensure_metrics_registered
          validate_dependencies!
          return if @registered

          register_metrics
          @registered = true
        end

        def register_metrics
          register_counters
          register_histograms
          register_gauges
        end

        def register_counters
          @jobs_enqueued = register_counter(
            :activejob_temporal_jobs_enqueued_total,
            "ActiveJob jobs successfully enqueued as Temporal workflows.",
            labels: %i[class queue]
          )
          @jobs_completed = register_counter(
            :activejob_temporal_jobs_completed_total,
            "ActiveJob jobs completed by Temporal activities.",
            labels: %i[class queue]
          )
          @jobs_failed = register_counter(
            :activejob_temporal_jobs_failed_total,
            "ActiveJob jobs failed during Temporal activity execution.",
            labels: %i[class queue error]
          )
          @retries = register_counter(
            :activejob_temporal_retries_total,
            "ActiveJob Temporal retry attempts that failed.",
            labels: %i[class error]
          )
        end

        def register_histograms
          @job_duration = register_histogram(
            :activejob_temporal_job_duration_seconds,
            "ActiveJob Temporal activity runner duration in seconds.",
            labels: %i[class],
            buckets: DURATION_BUCKETS
          )
          @payload_size = register_histogram(
            :activejob_temporal_payload_size_bytes,
            "Serialized ActiveJob payload size in bytes.",
            labels: %i[class],
            buckets: PAYLOAD_SIZE_BUCKETS
          )
        end

        def register_gauges
          @active_workers = register_gauge(
            :activejob_temporal_active_workers,
            "Active Temporal worker process state for this scrape target."
          )
          @active_tasks = register_gauge(
            :activejob_temporal_active_tasks,
            "Active Temporal activity tasks in this worker process."
          )
        end

        def register_counter(name, docstring, labels: [])
          registry.register(::Prometheus::Client::Counter.new(name, docstring: docstring, labels: labels))
        end

        def register_histogram(name, docstring, labels:, buckets:)
          registry.register(
            ::Prometheus::Client::Histogram.new(name, docstring: docstring, labels: labels, buckets: buckets)
          )
        end

        def register_gauge(name, docstring)
          registry.register(::Prometheus::Client::Gauge.new(name, docstring: docstring))
        end

        def monotonic_time
          @monotonic_clock.call
        end

        def label(value)
          (value || "unknown").to_s
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end

ActiveJob::Temporal::Observability.register_adapter(
  :prometheus,
  ActiveJob::Temporal::Observability::Prometheus
)
