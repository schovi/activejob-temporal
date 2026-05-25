# frozen_string_literal: true

require_relative "adapter"
require_relative "external_operation"
require "active_support/core_ext/string/inflections"

module ActiveJob
  module Temporal
    module JobPayloadChainBuilder
      ChainStepRoutingJob = Struct.new(:queue_name, :priority)

      private

      def apply_chain(payload, job)
        chain = chain_payloads_for(job)
        payload[:chain] = chain if chain.any?
      end

      def chain_payloads_for(job)
        Array(job.respond_to?(:temporal_chain) ? job.temporal_chain : nil).each_with_index.map do |chain_step, index|
          chain_payload_for(job, chain_step, index + 1)
        end
      end

      def chain_payload_for(root_job, chain_step, position)
        external_operation = ExternalOperation.normalize(chain_step)
        return external_chain_payload(external_operation) if external_operation

        job_class = chain_step_job_class(chain_step)
        options = chain_step_options(chain_step)
        queue_name = chain_step_queue_name(job_class, options)
        job_id = "#{root_job.job_id}:chain:#{position}"
        payload = base_chain_payload(job_class, job_id, queue_name, options)

        apply_chain_step_retry_policy(payload, job_class, job_id, queue_name)
        apply_temporal_options(payload, job_class)
        apply_rate_limits_for_class(payload, job_class)
        apply_workflow_interactions(payload, job_class)
        payload
      end

      def external_chain_payload(external_operation)
        {
          temporal_operation: external_operation.fetch(:temporal_operation),
          temporal_type: external_operation.fetch(:temporal_type),
          options: external_operation.fetch(:options)
        }
      end

      def base_chain_payload(job_class, job_id, queue_name, options)
        {
          job_class: job_class.name,
          job_id: job_id,
          queue_name: queue_name,
          arguments: [],
          executions: 0,
          exception_executions: {},
          default_activity_options: default_activity_options,
          activity_task_queue: chain_step_activity_task_queue(queue_name, options)
        }
      end

      def chain_step_job_class(chain_step)
        job_class_name = chain_step[:job_class] || chain_step["job_class"]
        job_class = job_class_name.constantize
        return job_class if job_class < ActiveJob::Base

        raise ArgumentError, "chain entries must be ActiveJob classes or configured jobs"
      end

      def chain_step_options(chain_step)
        chain_step[:options] || chain_step["options"] || {}
      end

      def chain_step_queue_name(job_class, options)
        queue_name = options[:queue] || options["queue"] || job_class.queue_name
        queue_name.to_s
      end

      def chain_step_activity_task_queue(queue_name, options)
        priority = options[:priority] || options["priority"]
        routing_job = ChainStepRoutingJob.new(queue_name, priority)
        Adapter.resolve_task_queue(routing_job, config: @config)
      end

      def apply_chain_step_retry_policy(payload, job_class, job_id, queue_name)
        retry_policy = retry_policy_for(job_class)
        payload[:retry_policy] = retry_policy
        return unless dead_letter_enabled?

        payload[:dead_letter] = dead_letter_metadata(
          job_class.name,
          job_id,
          queue_name,
          retry_policy,
          task_queue: payload.fetch(:activity_task_queue)
        )
      end

      def apply_rate_limits_for_class(payload, job_class)
        rate_limits = rate_limits_for(job_class)
        payload[:rate_limits] = rate_limits if rate_limits.any?
      end
    end
  end
end
