# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Adapter
      module_function

      # Builds deterministic workflow ID used for Temporal workflows.
      # @param job [ActiveJob::Base] ActiveJob instance being enqueued
      # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
      def build_workflow_id(job)
        "ajwf:#{job.class.name}:#{job.job_id}"
      end

      # Resolves the Temporal task queue name for a given job.
      # @param job [ActiveJob::Base] ActiveJob instance being enqueued
      # @return [String] Task queue name, optionally prefixed
      def resolve_task_queue(job)
        queue_name = job.queue_name.to_s.strip
        queue_name = "default" if queue_name.empty?

        prefix = ActiveJob::Temporal.config.task_queue_prefix
        return queue_name if prefix.nil? || prefix.to_s.strip.empty?

        "#{prefix}#{queue_name}"
      end
    end
  end
end
