# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "time"

require_relative "adapter"
require_relative "external_operation"
require_relative "workflow_id_builder"

module ActiveJob
  module Temporal
    module JobPayloadChildWorkflows
      ChildWorkflowRoutingJob = Struct.new(:queue_name, :priority)

      private

      def apply_child_workflows(payload, job)
        child_workflows = child_workflow_payloads_for(job)
        payload[:child_workflows] = child_workflows if child_workflows.any?
      end

      def child_workflow_payloads_for(job)
        child_workflows = job.respond_to?(:temporal_child_workflows) ? job.temporal_child_workflows : nil
        Array(child_workflows).each_with_index.map do |child_workflow, index|
          child_workflow_payload_for(job, child_workflow, index + 1)
        end
      end

      def child_workflow_payload_for(root_job, child_workflow, position)
        external_operation = ExternalOperation.normalize(child_workflow)
        return external_child_workflow_payload(external_operation) if external_operation

        job_class = child_workflow_job_class(child_workflow)
        options = child_workflow_options(child_workflow)
        queue_name = child_workflow_queue_name(job_class, options)
        job_id = "#{root_job.job_id}:child:#{position}"
        payload = base_child_workflow_payload(job_class, job_id, queue_name, options)

        apply_child_workflow_retry_policy(payload, job_class, job_id, queue_name)
        apply_temporal_options(payload, job_class)
        apply_rate_limits_for_class(payload, job_class)
        apply_workflow_interactions(payload, job_class)
        apply_child_workflow_search_attributes(payload, job_class, job_id, queue_name, options)
        payload
      end

      def external_child_workflow_payload(external_operation)
        {
          temporal_operation: external_operation.fetch(:temporal_operation),
          temporal_type: external_operation.fetch(:temporal_type),
          options: external_operation.fetch(:options)
        }
      end

      def base_child_workflow_payload(job_class, job_id, queue_name, options)
        task_queue = child_workflow_task_queue(queue_name, options)
        {
          job_class: job_class.name,
          job_id: job_id,
          workflow_id: child_workflow_id(job_class, job_id),
          queue_name: queue_name,
          arguments: [],
          executions: 0,
          exception_executions: {},
          default_activity_options: default_activity_options,
          activity_task_queue: task_queue,
          workflow_task_queue: task_queue
        }
      end

      def child_workflow_job_class(child_workflow)
        job_class_name = child_workflow[:job_class] || child_workflow["job_class"]
        job_class = job_class_name.constantize
        return job_class if job_class < ActiveJob::Base

        raise ArgumentError, "child_workflows entries must be ActiveJob classes or configured jobs"
      end

      def child_workflow_options(child_workflow)
        child_workflow[:options] || child_workflow["options"] || {}
      end

      def child_workflow_queue_name(job_class, options)
        queue_name = options[:queue] || options["queue"] || job_class.queue_name
        queue_name.to_s
      end

      def child_workflow_task_queue(queue_name, options)
        priority = options[:priority] || options["priority"]
        routing_job = ChildWorkflowRoutingJob.new(queue_name, priority)
        Adapter.resolve_task_queue(routing_job, config: @config)
      end

      def child_workflow_id(job_class, job_id)
        workflow_id = WorkflowIdBuilder.default_from_job_class(job_class, job_id)
        WorkflowIdBuilder.validate!(workflow_id)
        workflow_id
      end

      def apply_child_workflow_retry_policy(payload, job_class, job_id, queue_name)
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

      def apply_child_workflow_search_attributes(payload, job_class, job_id, queue_name, options)
        return unless @config.respond_to?(:enable_search_attributes) && @config.enable_search_attributes

        tags = options[:tags] || options["tags"] || []
        payload[:search_attributes] = {
          job_class: job_class.name,
          job_id: job_id,
          queue_name: queue_name,
          enqueued_at: Time.now.utc.iso8601,
          tags: tags
        }
      end
    end
  end
end
