# frozen_string_literal: true

require "active_job"

module ActiveJob
  module Temporal
    # Helper methods for the TemporalAdapter.
    #
    # This module provides utility functions for building workflow IDs and resolving
    # task queue names. Used internally by the adapter.
    module Adapter
      module_function

      # Builds deterministic workflow ID used for Temporal workflows.
      #
      # Creates a unique, reproducible workflow ID from the job class and job ID.
      # This enables idempotent enqueuing: duplicate enqueue calls with the same job_id
      # will be rejected by Temporal's FAIL conflict policy (returning nil, not raising).
      #
      # @param job [ActiveJob::Base] ActiveJob instance being enqueued
      # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
      #
      # @note Idempotency Guarantee
      #   The workflow ID format ensures that jobs with the same job_id will never
      #   execute twice. This is critical for preventing duplicate processing in
      #   distributed systems.
      #
      # @example Basic usage
      #   job = MyJob.new
      #   job.job_id # => "abc-123"
      #   build_workflow_id(job) # => "ajwf:MyJob:abc-123"
      #
      # @example Duplicate enqueue (returns nil, not error)
      #   MyJob.set(job_id: "unique-id").perform_later("arg")  # First enqueue succeeds
      #   MyJob.set(job_id: "unique-id").perform_later("arg")  # Second enqueue returns nil
      #
      # @see TemporalAdapter#enqueue
      def build_workflow_id(job)
        "ajwf:#{job.class.name}:#{job.job_id}"
      end

      # Resolves the Temporal task queue name for a given job.
      #
      # Extracts the queue name from the job and applies the configured task_queue_prefix
      # if present. Defaults to "default" if queue_name is blank.
      #
      # @param job [ActiveJob::Base] ActiveJob instance being enqueued
      # @return [String] Task queue name, optionally prefixed
      # @example Without prefix
      #   job.queue_name # => "mailers"
      #   resolve_task_queue(job) # => "mailers"
      # @example With prefix
      #   ActiveJob::Temporal.config.task_queue_prefix = "myapp-"
      #   job.queue_name # => "mailers"
      #   resolve_task_queue(job) # => "myapp-mailers"
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
    # ActiveJob queue adapter for Temporal workflows.
    #
    # This adapter integrates ActiveJob with Temporal by starting workflows for each
    # enqueued job. It translates ActiveJob's `perform_later` and `set(wait:).perform_later`
    # into Temporal workflow starts with the AjWorkflow.
    #
    # @note Idempotent Enqueuing
    #   Jobs with the same job_id will not be enqueued twice. The adapter uses
    #   FAIL conflict policy, so duplicate enqueue attempts return nil (not an error).
    #
    # @note Transaction Safety
    #   The adapter implements `enqueue_after_transaction_commit?`, which defers
    #   workflow starts until the current database transaction commits. This prevents
    #   workflows from starting for rolled-back jobs.
    #
    # @example Basic usage
    #   class MyJob < ApplicationJob
    #     self.queue_adapter = :temporal
    #     def perform(arg)
    #       # job logic
    #     end
    #   end
    #   MyJob.perform_later("arg")
    #
    # @example Scheduled job
    #   MyJob.set(wait: 1.hour).perform_later("arg")
    class TemporalAdapter
      # Enqueues a job for immediate execution on Temporal by starting the AjWorkflow.
      #
      # @param job [ActiveJob::Base] the job instance provided by ActiveJob
      # @return [Object, nil] workflow run handle (if provided by Temporal SDK), or nil if duplicate
      #
      # @raise [ActiveJob::SerializationError] if payload serialization fails or exceeds max_payload_size_kb
      # @raise [ActiveJob::EnqueueError] if the Temporal client cannot start the workflow
      # @raise [ActiveJob::Temporal::ConfigurationError] if configuration is invalid
      #
      # @note FAIL Conflict Policy
      #   Duplicate job_id values return nil rather than raising an error. This is
      #   Temporal's FAIL conflict policy in action.
      #
      # @example Basic usage
      #   adapter = TemporalAdapter.new
      #   job = MyJob.new("arg1", "arg2")
      #   adapter.enqueue(job)
      #
      # @example Handling serialization errors
      #   begin
      #     MyJob.perform_later(huge_object)
      #   rescue ActiveJob::SerializationError => e
      #     Rails.logger.error("Payload too large: #{e.message}")
      #     MyJob.perform_later(huge_object.id)  # Pass ID instead
      #   end
      #
      # @example Handling configuration errors
      #   begin
      #     MyJob.perform_later("arg")
      #   rescue ActiveJob::Temporal::ConfigurationError => e
      #     # Configuration validation failed
      #     Rails.logger.fatal("Invalid Temporal configuration: #{e.message}")
      #   end
      #
      # @example Handling enqueue errors (cluster unreachable)
      #   begin
      #     MyJob.perform_later("arg")
      #   rescue ActiveJob::EnqueueError => e
      #     # Temporal cluster is down or network issue
      #     Rails.logger.error("Cannot enqueue job: #{e.message}")
      #     # Consider queuing to fallback system or retrying later
      #   end
      #
      # @see #enqueue_at
      # @see https://docs.temporal.io/workflows#workflow-id-reuse-policy Temporal Workflow ID Policies
      def enqueue(job)
        payload = build_payload(job)
        enqueue_with_payload(job, payload)
      end

      # Enqueues a job for execution at a specific time by starting the AjWorkflow immediately.
      #
      # The workflow starts immediately but sleeps (non-blockingly) until the scheduled time
      # before executing the activity. This leverages Temporal's durable timers.
      #
      # @param job [ActiveJob::Base] the job instance provided by ActiveJob
      # @param timestamp [Integer, Float] UNIX timestamp when the job should be executed
      # @return [Object, nil] workflow run handle (if provided by Temporal SDK), or nil if duplicate
      #
      # @raise [ActiveJob::SerializationError] if payload serialization fails or exceeds max_payload_size_kb
      # @raise [ActiveJob::EnqueueError] if the Temporal client cannot start the workflow
      # @raise [ActiveJob::Temporal::ConfigurationError] if configuration is invalid
      #
      # @note Non-Blocking Sleep
      #   The workflow uses Temporal's durable timer mechanism, so scheduled jobs
      #   do not consume worker resources while waiting.
      #
      # @example Basic usage
      #   adapter = TemporalAdapter.new
      #   job = MyJob.new("arg")
      #   adapter.enqueue_at(job, 1.hour.from_now.to_i)
      #
      # @example Scheduling with ActiveJob DSL
      #   MyJob.set(wait: 1.hour).perform_later("arg")
      #
      # @example Scheduling with wait_until
      #   MyJob.set(wait_until: Date.tomorrow.noon).perform_later("arg")
      #
      # @example Far-future scheduling (durable timer benefits)
      #   # Schedule a job 30 days in the future
      #   MyJob.set(wait: 30.days).perform_later("reminder", user_id: 123)
      #   # The workflow sleeps for 30 days without consuming resources
      #
      # @see #enqueue
      # @see Workflows::AjWorkflow#sleep_until
      def enqueue_at(job, timestamp)
        scheduled_time = Time.at(timestamp)
        payload = build_payload(job, scheduled_at: scheduled_time)

        enqueue_with_payload(job, payload)
      end

      # Signals ActiveJob to defer enqueuing until after the current database transaction commits.
      #
      # This prevents Temporal workflows from starting for jobs created within rolled-back
      # database transactions. Rails will automatically defer `enqueue` and `enqueue_at` calls
      # until the transaction commits.
      #
      # @return [Boolean] always returns true
      # @example Transaction-safe enqueuing
      #   ActiveRecord::Base.transaction do
      #     user = User.create!(name: "Alice")
      #     MyJob.perform_later(user) # Deferred until commit
      #     raise ActiveRecord::Rollback # Job is NOT enqueued
      #   end
      #
      # @example Ensuring job runs after DB commit
      #   ActiveRecord::Base.transaction do
      #     order = Order.create!(amount: 100)
      #     PaymentJob.perform_later(order.id)
      #     # Job will not start until transaction commits successfully
      #   end
      def enqueue_after_transaction_commit?
        true
      end

      private

      # Enqueues a workflow with the given payload and options.
      # @api private
      def enqueue_with_payload(job, payload)
        workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)
        task_queue = ActiveJob::Temporal::Adapter.resolve_task_queue(job)
        client = ActiveJob::Temporal.client

        options = {
          id: workflow_id,
          task_queue: task_queue,
          id_conflict_policy: Temporalio::WorkflowIDConflictPolicy::FAIL
        }

        # Add search attributes if configured
        if ActiveJob::Temporal.config.respond_to?(:enable_search_attributes) && ActiveJob::Temporal.config.enable_search_attributes
          search_attributes = ActiveJob::Temporal::SearchAttributes.for(job)
          options[:search_attributes] = search_attributes
        end

        start_workflow(client, payload, options, job)
      end

      # Builds a payload hash from a job instance.
      # Includes the job's retry policy for use in the workflow.
      # @api private
      def build_payload(job, scheduled_at: nil)
        payload = ActiveJob::Temporal::Payload.from_job(job, scheduled_at: scheduled_at)

        # Build and add retry policy from job class
        retry_policy = ActiveJob::Temporal::RetryMapper.for(job.class)
        payload[:retry_policy] = retry_policy

        payload
      end

      # Starts the Temporal workflow with the given options.
      # @api private
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

      # Checks if error indicates workflow was already started (duplicate job_id).
      # @api private
      def workflow_already_started?(error)
        return false unless defined?(Temporalio::Client::WorkflowAlreadyStartedError)

        error.is_a?(Temporalio::Client::WorkflowAlreadyStartedError)
      end

      # Logs enqueue event with structured metadata.
      # @api private
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

      # Logs enqueue event using options hash and payload.
      # @api private
      def log_enqueued_with_options(job, options, payload, duplicate:)
        log_enqueued(
          job,
          options[:id],
          options[:task_queue],
          duplicate: duplicate,
          scheduled_at: payload[:scheduled_at]
        )
      end

      # Builds error message for enqueue failures.
      # @api private
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
