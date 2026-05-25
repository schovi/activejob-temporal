# frozen_string_literal: true

require_relative "payload"
require_relative "job_payload_child_workflows"
require_relative "job_payload_chain_builder"
require_relative "job_payload_dependencies"
require_relative "job_payload_rate_limits"
require_relative "job_payload_workflow_interactions"
require_relative "observability"
require_relative "retry_mapper"

module ActiveJob
  module Temporal
    # rubocop:disable Metrics/ClassLength
    class JobPayloadBuilder
      include JobPayloadChildWorkflows
      include JobPayloadChainBuilder
      include JobPayloadDependencies
      include JobPayloadRateLimits
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

      def build(job, scheduled_at: nil, encryption_context: nil)
        payload = base_payload_for(job, scheduled_at)
        payload[:default_activity_options] = default_activity_options
        Observability.inject_trace_context(payload, observability_attributes_for(job, encryption_context))

        apply_retry_policy(payload, job)
        apply_temporal_options(payload, job.class)
        apply_workflow_identity(payload, job.class)
        apply_rate_limits(payload, job)
        apply_workflow_interactions(payload, job.class)
        apply_child_workflows(payload, job)
        apply_chain(payload, job)
        apply_dependencies(payload, job)
        apply_continue_as_new(payload)
        apply_local_activity_helpers(payload)

        payload = transport_payload(payload, job, scheduled_at, encryption_context)
        Payload.enforce_size!(payload, metrics_payload: metrics_payload_for(job), config: @config)
        payload
      end

      private

      def base_payload_for(job, scheduled_at)
        Payload.from_job(
          job,
          scheduled_at:,
          enforce_size: false,
          encrypt: false,
          offload: false,
          config: @config
        )
      end

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

      def apply_workflow_identity(payload, job_class)
        workflow_name = extract_temporal_workflow_name(job_class)
        return unless workflow_name

        identity = { workflow_name: workflow_name }
        workflow_id_prefix = extract_temporal_workflow_id_prefix(job_class)
        identity[:workflow_id_prefix] = workflow_id_prefix if workflow_id_prefix
        payload[:workflow_identity] = identity
      end

      def metrics_payload_for(job)
        {
          job_class: job.class.name,
          job_id: job.job_id,
          queue_name: job.queue_name
        }
      end

      def observability_attributes_for(job, encryption_context)
        Observability.attributes_from_job(
          job,
          workflow_id: encryption_context&.fetch(:workflow_id, nil),
          namespace: @config.namespace,
          task_queue: Adapter.resolve_task_queue(job, config: @config)
        )
      end

      def transport_payload(payload, job, scheduled_at, encryption_context)
        encrypted_payload = Payload.encrypt_payload(payload, config: @config, encryption_context: encryption_context)
        Payload.offload_payload(
          encrypted_payload,
          metadata: storage_metadata_for(job, scheduled_at, encryption_context),
          config: @config
        )
      end

      def storage_metadata_for(job, scheduled_at, encryption_context)
        metrics_payload_for(job).merge(
          namespace: @config.namespace,
          workflow_id: encryption_context&.fetch(:workflow_id, nil),
          scheduled_at: scheduled_at.respond_to?(:iso8601) ? scheduled_at.iso8601 : scheduled_at
        )
      end

      def apply_continue_as_new(payload)
        threshold = @config.continue_as_new_history_event_threshold
        return unless threshold

        payload[:continue_as_new] = { history_event_threshold: threshold }
      end

      def apply_local_activity_helpers(payload)
        helpers = Array(@config.local_activity_helpers).filter_map do |helper|
          helper_name = helper.to_s.strip
          helper_name unless helper_name.empty?
        end.uniq
        payload[:local_activity_helpers] = helpers if helpers.any?
      end

      def extract_temporal_options(job_class)
        return {} unless job_class.respond_to?(:temporal_options)

        job_class.temporal_options
      end

      def extract_temporal_workflow_name(job_class)
        return unless job_class.respond_to?(:temporal_workflow_name)

        job_class.temporal_workflow_name
      end

      def extract_temporal_workflow_id_prefix(job_class)
        return unless job_class.respond_to?(:temporal_workflow_id_prefix)

        job_class.temporal_workflow_id_prefix
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
        {
          queue: @config.dead_letter_queue,
          job_class: job_class_name,
          job_id: job_id,
          queue_name: queue_name,
          task_queue: task_queue,
          after_attempts: dead_letter_attempt_limit(retry_policy),
          auto_discard_after_seconds: @config.dead_letter_auto_discard_after&.to_f
        }.compact
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
    # rubocop:enable Metrics/ClassLength
  end
end
