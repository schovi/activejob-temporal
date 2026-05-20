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
        payload = Payload.from_job(job, scheduled_at: scheduled_at)
        payload[:default_activity_options] = default_activity_options

        retry_policy = RetryMapper.for(job.class)
        payload[:retry_policy] = retry_policy

        temporal_options = extract_temporal_options(job.class)
        payload[:temporal_options] = temporal_options if temporal_options.any?

        payload
      end

      private

      def extract_temporal_options(job_class)
        return {} unless job_class.respond_to?(:temporal_options)

        job_class.temporal_options
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
