# frozen_string_literal: true

require_relative "metrics/null_provider"
require_relative "metrics/prometheus"

module ActiveJob
  module Temporal
    module Metrics
      class << self
        def provider(config = ActiveJob::Temporal.config)
          return prometheus_provider if prometheus_enabled?(config)

          null_provider
        end

        def reset!
          @prometheus_provider = nil
          @null_provider = nil
        end

        def record_enqueue(job:, duplicate:)
          provider.record_enqueue(
            job_class: job_class_name(job),
            queue: job_queue_name(job),
            duplicate: duplicate
          )
        end

        def observe_payload_size(payload:, bytes:)
          provider.observe_payload_size(
            job_class: payload_job_class(payload),
            bytes: bytes
          )
        end

        def instrument_perform(payload, &)
          provider.instrument_perform(
            job_class: payload_job_class(payload),
            queue: payload_queue(payload),
            &
          )
        end

        def record_retry(payload, error)
          return unless retry_attempt?

          provider.record_retry(
            job_class: payload_job_class(payload),
            error: error.class.name
          )
        end

        def render
          provider.render
        end

        def record_worker_started
          provider.record_worker_started
        end

        def record_worker_stopped
          provider.record_worker_stopped
        end

        def record_active_tasks(count)
          provider.record_active_tasks(count)
        end

        private

        def prometheus_enabled?(config)
          config.respond_to?(:metrics_provider) && config.metrics_provider.to_sym == :prometheus
        end

        def prometheus_provider
          @prometheus_provider ||= Prometheus.new
        end

        def null_provider
          @null_provider ||= NullProvider.new
        end

        def job_class_name(job)
          job.class.name.to_s
        end

        def job_queue_name(job)
          (job.queue_name || "default").to_s
        end

        def payload_job_class(payload)
          (payload[:job_class] || payload["job_class"] || "UnknownJob").to_s
        end

        def payload_queue(payload)
          (payload[:queue_name] || payload["queue_name"] || "default").to_s
        end

        def retry_attempt?
          return false unless defined?(Temporalio::Activity::Context)
          return false unless Temporalio::Activity::Context.exist?

          info = Temporalio::Activity::Context.current.info
          info.respond_to?(:attempt) && info.attempt.to_i > 1
        rescue StandardError
          false
        end
      end
    end
  end
end
