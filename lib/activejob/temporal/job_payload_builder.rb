# frozen_string_literal: true

require_relative "payload"
require_relative "retry_mapper"

module ActiveJob
  module Temporal
    class JobPayloadBuilder
      TIMEOUT_CONFIG_ATTRIBUTES = {
        default_activity_timeout: :start_to_close_timeout,
        default_schedule_to_close_timeout: :schedule_to_close_timeout,
        default_schedule_to_start_timeout: :schedule_to_start_timeout,
        default_heartbeat_timeout: :heartbeat_timeout
      }.freeze

      def initialize(config)
        @config = config
      end

      def build(job, scheduled_at: nil)
        payload = Payload.from_job(job, scheduled_at: scheduled_at, enforce_size: false, config: @config)
        payload[:default_activity_options] = default_activity_options

        retry_policy = RetryMapper.for(job.class)
        apply_dead_letter_attempt_limit(retry_policy)
        payload[:retry_policy] = retry_policy
        payload[:dead_letter] = dead_letter_metadata(job, retry_policy) if dead_letter_enabled?

        temporal_options = extract_temporal_options(job.class)
        payload[:temporal_options] = temporal_options if temporal_options.any?

        Payload.enforce_size!(payload, metrics_payload: metrics_payload_for(job), config: @config)
        payload
      end

      private

      def metrics_payload_for(job)
        {
          job_class: job.class.name,
          job_id: job.job_id,
          queue_name: job.queue_name
        }
      end

      def extract_temporal_options(job_class)
        return {} unless job_class.respond_to?(:temporal_options)

        job_class.temporal_options
      end

      def dead_letter_enabled?
        @config.respond_to?(:dead_letter_queue) && @config.dead_letter_queue.to_s.strip.present?
      end

      def apply_dead_letter_attempt_limit(retry_policy)
        return unless dead_letter_enabled?
        return unless @config.dead_letter_after_attempts

        retry_policy[:maximum_attempts] = @config.dead_letter_after_attempts
      end

      def dead_letter_metadata(job, retry_policy)
        metadata = {
          queue: @config.dead_letter_queue,
          job_class: job.class.name,
          job_id: job.job_id,
          queue_name: job.queue_name
        }
        after_attempts = dead_letter_attempt_limit(retry_policy)
        metadata[:after_attempts] = after_attempts if after_attempts
        metadata
      end

      def dead_letter_attempt_limit(retry_policy)
        configured_limit = @config.dead_letter_after_attempts
        return configured_limit if configured_limit

        attempts = retry_policy[:maximum_attempts] || retry_policy["maximum_attempts"]
        attempts if attempts.respond_to?(:positive?) && attempts.positive?
      end

      def default_activity_options
        TIMEOUT_CONFIG_ATTRIBUTES.each_with_object({}) do |(config_attribute, option_name), options|
          value = @config.public_send(config_attribute)
          options[option_name] = normalize_duration(value) if value
        end
      end

      def normalize_duration(value)
        return value.to_f if value.respond_to?(:to_f)

        value
      end
    end
  end
end
