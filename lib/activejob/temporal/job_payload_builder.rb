# frozen_string_literal: true

require_relative "payload"
require_relative "job_payload_chain_builder"
require_relative "job_payload_dependencies"
require_relative "job_payload_workflow_interactions"
require_relative "rate_limit_options"
require_relative "retry_mapper"

module ActiveJob
  module Temporal
    class JobPayloadBuilder
      include JobPayloadChainBuilder
      include JobPayloadDependencies
      include JobPayloadWorkflowInteractions

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
        payload = Payload.from_job(job, scheduled_at:, enforce_size: false, encrypt: false, config: @config)
        payload[:default_activity_options] = default_activity_options

        apply_retry_policy(payload, job)
        apply_temporal_options(payload, job.class)
        apply_rate_limits(payload, job)
        apply_workflow_interactions(payload, job.class)
        apply_chain(payload, job)
        apply_dependencies(payload, job)

        payload = Payload.encrypt_payload(payload, config: @config)
        Payload.enforce_size!(payload, metrics_payload: metrics_payload_for(job), config: @config)
        payload
      end

      private

      def apply_retry_policy(payload, job)
        retry_policy = retry_policy_for(job.class)
        payload[:retry_policy] = retry_policy
        return unless dead_letter_enabled?

        payload[:dead_letter] = dead_letter_metadata(job.class.name, job.job_id, job.queue_name, retry_policy)
      end

      def apply_temporal_options(payload, job_class)
        temporal_options = extract_temporal_options(job_class)
        payload[:temporal_options] = temporal_options if temporal_options.any?
      end

      def apply_rate_limits(payload, job)
        rate_limits = rate_limits_for(job.class)
        payload[:rate_limits] = rate_limits if rate_limits.any?
      end

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

      def rate_limits_for(job_class)
        rate_limits = [
          configured_global_rate_limit,
          configured_job_rate_limit(job_class)
        ].compact
        validate_rate_limiter!(rate_limits)
        rate_limits
      end

      def configured_global_rate_limit
        return unless @config.respond_to?(:global_rate_limit) && @config.global_rate_limit

        normalize_rate_limit(@config.global_rate_limit, default_key: "activejob-temporal:global")
      end

      def configured_job_rate_limit(job_class)
        return unless job_class.respond_to?(:rate_limit)

        rate_limit = job_class.rate_limit
        return if rate_limit.empty?

        normalize_rate_limit(rate_limit, default_key: "activejob-temporal:job:#{job_class.name}")
      end

      def normalize_rate_limit(rate_limit, default_key:)
        normalized = RateLimitOptions.normalize_hash(rate_limit)
        normalized[:key] ||= default_key
        normalized
      end

      def validate_rate_limiter!(rate_limits)
        return if rate_limits.empty?
        return if @config.respond_to?(:rate_limiter) && @config.rate_limiter

        raise ConfigurationError, "rate_limiter is required when rate limits are configured"
      end

      def dead_letter_enabled?
        @config.respond_to?(:dead_letter_queue) && @config.dead_letter_queue.to_s.strip.present?
      end

      def apply_dead_letter_attempt_limit(retry_policy)
        return unless dead_letter_enabled?
        return unless @config.dead_letter_after_attempts

        retry_policy[:maximum_attempts] = @config.dead_letter_after_attempts
      end

      def dead_letter_metadata(job_class_name, job_id, queue_name, retry_policy, task_queue: nil)
        metadata = {
          queue: @config.dead_letter_queue,
          job_class: job_class_name,
          job_id: job_id,
          queue_name: queue_name
        }
        metadata[:task_queue] = task_queue if task_queue
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

      def retry_policy_for(job_class)
        retry_policy = RetryMapper.for(job_class)
        apply_dead_letter_attempt_limit(retry_policy)
        retry_policy
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
