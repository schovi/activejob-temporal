# frozen_string_literal: true

require "prometheus/client"
require "prometheus/client/formats/text"

module ActiveJob
  module Temporal
    module Metrics
      class Prometheus
        DURATION_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120].freeze
        PAYLOAD_SIZE_BUCKETS = [512, 1024, 2_048, 4_096, 8_192, 16_384, 32_768, 65_536, 131_072, 262_144,
                                524_288, 1_048_576].freeze

        attr_reader :registry

        def initialize(registry: ::Prometheus::Client::Registry.new,
                       monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @registry = registry
          @monotonic_clock = monotonic_clock
          register_metrics
        end

        def record_enqueue(job_class:, queue:, duplicate: false)
          return if duplicate

          @jobs_enqueued.increment(labels: { class: label(job_class), queue: label(queue) })
        end

        def observe_payload_size(job_class:, bytes:)
          @payload_size.observe(bytes, labels: { class: label(job_class) })
        end

        def instrument_perform(job_class:, queue:)
          started_at = monotonic_time

          result = yield
          @jobs_completed.increment(labels: { class: label(job_class), queue: label(queue) })
          result
        rescue StandardError => e
          @jobs_failed.increment(labels: { class: label(job_class), queue: label(queue), error: e.class.name })
          raise
        ensure
          @job_duration.observe(monotonic_time - started_at, labels: { class: label(job_class) }) if started_at
        end

        def record_retry(job_class:, error:)
          @retries.increment(labels: { class: label(job_class), error: label(error) })
        end

        def record_worker_started
          @active_workers.set(1)
        end

        def record_worker_stopped
          @active_workers.set(0)
          record_active_tasks(0)
        end

        def record_active_tasks(count)
          @active_tasks.set(count)
        end

        def render
          ::Prometheus::Client::Formats::Text.marshal(registry)
        end

        private

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
          value.to_s
        end
      end
    end
  end
end
