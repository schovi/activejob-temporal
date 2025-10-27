# frozen_string_literal: true

require "active_job"

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

module ActiveJob
  module QueueAdapters
    class TemporalAdapter
      # Enqueues a job for execution on Temporal by starting the AjWorkflow.
      # @param job [ActiveJob::Base] the job instance provided by ActiveJob
      # @raise [ActiveJob::SerializationError] when payload serialization fails
      # @raise [ActiveJob::EnqueueError] when the Temporal client cannot start the workflow
      # @return [Object, nil] workflow run handle (if provided by Temporal SDK)
      def enqueue(job)
        payload = build_payload(job)
        workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)
        task_queue = ActiveJob::Temporal::Adapter.resolve_task_queue(job)
        search_attributes = ActiveJob::Temporal::SearchAttributes.for(job)
        client = ActiveJob::Temporal.client

        options = {
          id: workflow_id,
          task_queue: task_queue,
          id_conflict_policy: :reject,
          search_attributes: search_attributes
        }

        start_workflow(client, payload, options, job)
      end

      private

      def build_payload(job)
        payload = ActiveJob::Temporal::Payload.from_job(job)
        payload[:retry_policy] = ActiveJob::Temporal::RetryMapper.for(job.class)
        payload
      end

      def start_workflow(client, payload, options, job)
        workflow_class = ActiveJob::Temporal::Workflows::AjWorkflow
        workflow_id = options[:id]
        task_queue = options[:task_queue]

        handle = client.start_workflow(workflow_class, payload, **options)

        log_enqueued(job, workflow_id, task_queue, duplicate: false)

        handle
      rescue StandardError => e
        if workflow_already_started?(e)
          log_enqueued(job, workflow_id, task_queue, duplicate: true)
          return nil
        end

        message = format(
          "Failed to enqueue job %<job_class>s (%<job_id>s): %<error>s",
          job_class: job.class.name,
          job_id: job.job_id,
          error: e.message
        )

        raise ActiveJob::EnqueueError, message
      end

      def workflow_already_started?(error)
        return false unless defined?(Temporalio::Client::WorkflowAlreadyStartedError)

        error.is_a?(Temporalio::Client::WorkflowAlreadyStartedError)
      end

      def log_enqueued(job, workflow_id, task_queue, duplicate:)
        ActiveJob::Temporal::Logger.log_event(
          "workflow_enqueued",
          workflow_id: workflow_id,
          job_class: job.class.name,
          job_id: job.job_id,
          queue: job.queue_name,
          task_queue: task_queue,
          duplicate: duplicate
        )
      end
    end
  end
end
