# frozen_string_literal: true

require "digest"

module ActiveJob
  module Temporal
    module AuditLog
      extend self

      SENSITIVE_ATTRIBUTE_NAMES = %w[
        arguments
        args
        cause
        error
        error_message
        exception
        message
        payload
        result
        target
      ].freeze

      def record(event_name, attributes = {})
        config = ActiveJob::Temporal.config
        return unless config.audit_log

        logger = config.audit_logger || config.logger
        Logger.log_to(logger, :info, event_name, sanitized_attributes(attributes))
      end

      def job_attributes_from_payload(payload)
        payload = payload.to_h
        attributes = {
          job_class: value_from(payload, :job_class),
          job_id: value_from(payload, :job_id),
          queue: value_from(payload, :queue_name),
          executions: value_from(payload, :executions),
          scheduled_at: value_from(payload, :scheduled_at)
        }

        attributes.compact
      end

      def activity_attributes_from_payload(payload)
        job_attributes_from_payload(payload)
          .merge(activity_context_attributes)
          .merge(worker_id: ActiveJob::Temporal.config.identity)
          .compact
      end

      def error_attributes(error)
        {
          error_class: error.class.name,
          error_fingerprint: error_fingerprint(error)
        }.compact
      end

      def cancelled_error?(error)
        defined?(Temporalio::Error::CanceledError) && error.is_a?(Temporalio::Error::CanceledError)
      end

      def elapsed_milliseconds(started_at)
        ((monotonic_time - started_at) * 1000).round(2)
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      private

      def sanitized_attributes(attributes)
        attributes.to_h.each_with_object({}) do |(key, value), result|
          next if SENSITIVE_ATTRIBUTE_NAMES.include?(key.to_s)
          next if value.nil?

          result[key] = value
        end
      end

      def value_from(hash, key)
        hash[key] || hash[key.to_s]
      end

      def activity_context_attributes
        return {} unless defined?(Temporalio::Activity::Context)
        return {} unless Temporalio::Activity::Context.exist?

        activity_info = Temporalio::Activity::Context.current.info
        {
          workflow_id: context_value(activity_info, :workflow_id),
          run_id: context_value(activity_info, :workflow_run_id, :run_id),
          attempt: context_value(activity_info, :attempt)
        }.compact
      rescue StandardError
        {}
      end

      def context_value(object, *methods)
        methods.each do |method_name|
          return object.public_send(method_name) if object.respond_to?(method_name)
        end

        nil
      end

      def error_fingerprint(error)
        source = [
          error.class.name,
          error.message,
          *Array(error.backtrace).first(20)
        ].compact.join("\n")

        Digest::SHA256.hexdigest(source)
      end
    end
  end
end
