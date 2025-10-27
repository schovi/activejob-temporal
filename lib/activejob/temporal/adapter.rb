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
        enqueue_with_payload(job, payload)
      end

      # Enqueues a job for execution at a specific time by starting the AjWorkflow immediately.
      # @param job [ActiveJob::Base] the job instance provided by ActiveJob
      # @param timestamp [Integer] UNIX timestamp when the job should be executed
      # @raise [ActiveJob::SerializationError] when payload serialization fails
      # @raise [ActiveJob::EnqueueError] when the Temporal client cannot start the workflow
      # @return [Object, nil] workflow run handle (if provided by Temporal SDK)
      def enqueue_at(job, timestamp)
        scheduled_time = Time.at(timestamp)
        payload = build_payload(job, scheduled_at: scheduled_time)

        enqueue_with_payload(job, payload)
      end

      # Signals ActiveJob to defer enqueuing until after the current database transaction commits.
      # This prevents Temporal workflows from starting for rolled-back transactions.
      def enqueue_after_transaction_commit?
        true
      end

      private

      def enqueue_with_payload(job, payload)
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

      def build_payload(job, scheduled_at: nil)
        payload = ActiveJob::Temporal::Payload.from_job(job, scheduled_at: scheduled_at)
        payload[:retry_policy] = ActiveJob::Temporal::RetryMapper.for(job.class)
        payload
      end

      def start_workflow(client, payload, options, job)
        workflow_class = ActiveJob::Temporal::Workflows::AjWorkflow
        handle = client.start_workflow(workflow_class, payload, **options)

        log_enqueued_with_options(job, options, payload, duplicate: false)

        handle
      rescue StandardError => e
        if workflow_already_started?(e)
          log_enqueued_with_options(job, options, payload, duplicate: true)
          return nil
        end

        raise ActiveJob::EnqueueError, build_enqueue_error_message(job, e)
      end

      def workflow_already_started?(error)
        return false unless defined?(Temporalio::Client::WorkflowAlreadyStartedError)

        error.is_a?(Temporalio::Client::WorkflowAlreadyStartedError)
      end

      def log_enqueued(job, workflow_id, task_queue, duplicate:, scheduled_at: nil)
        attributes = {
          workflow_id: workflow_id,
          job_class: job.class.name,
          job_id: job.job_id,
          queue: job.queue_name,
          task_queue: task_queue,
          duplicate: duplicate
        }
        attributes[:scheduled_at] = scheduled_at if scheduled_at

        ActiveJob::Temporal::Logger.log_event("workflow_enqueued", **attributes)
      end

      def log_enqueued_with_options(job, options, payload, duplicate:)
        log_enqueued(
          job,
          options[:id],
          options[:task_queue],
          duplicate: duplicate,
          scheduled_at: payload[:scheduled_at]
        )
      end

      def build_enqueue_error_message(job, error)
        format(
          "Failed to enqueue job %<job_class>s (%<job_id>s): %<error>s",
          job_class: job.class.name,
          job_id: job.job_id,
          error: error.message
        )
      end
    end
  end
end
