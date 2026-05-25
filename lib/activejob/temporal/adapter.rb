# frozen_string_literal: true

require "active_job"
require "active_job/queue_adapters/abstract_adapter"
require_relative "workflow_id_builder"

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
      # Delegates ID construction to WorkflowIdBuilder while preserving the public
      # helper used by integrations and tests. Creates a unique, reproducible
      # workflow ID from the job class and job ID.
      # This enables idempotent enqueuing: duplicate enqueue calls with the same job_id
      # will be rejected by Temporal's FAIL conflict policy.
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
      # @example Duplicate enqueue
      #   MyJob.set(job_id: "unique-id").perform_later("arg")  # First enqueue succeeds
      #   MyJob.set(job_id: "unique-id").perform_later("arg")  # Second enqueue returns false
      #
      # @see TemporalAdapter#enqueue
      def build_workflow_id(job)
        WorkflowIdBuilder.new(configured_workflow_id_generator).build(job)
      end

      def configured_workflow_id_generator
        ActiveJob::Temporal.config.workflow_id_generator if ActiveJob::Temporal.respond_to?(:config)
      end
      private_class_method :configured_workflow_id_generator

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
      def resolve_task_queue(job, config: ActiveJob::Temporal.config)
        queue_name = priority_task_queue(job, config) || job.queue_name.to_s.strip
        queue_name = "default" if queue_name.empty?

        prefix = config.task_queue_prefix
        return queue_name if prefix.nil? || prefix.to_s.strip.empty?

        "#{prefix}#{queue_name}"
      end

      def priority_task_queue(job, config)
        priority_task_queues = config.respond_to?(:priority_task_queues) ? config.priority_task_queues : {}
        return unless priority_task_queues.is_a?(Hash) && priority_task_queues.any?

        return unless job.respond_to?(:priority)

        job_priority = job.priority
        return unless job_priority.is_a?(Integer)

        priority_task_queues[job_priority]&.to_s&.strip
      end
      private_class_method :priority_task_queue
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
    #   FAIL conflict policy, so duplicate enqueue attempts surface as
    #   DuplicateEnqueueError through ActiveJob's enqueue status.
    #
    # @note Transaction Safety
    #   Jobs using the Temporal adapter are opted into ActiveJob's
    #   `enqueue_after_transaction_commit` setting. This defers workflow starts
    #   until the current database transaction commits and prevents workflows from
    #   starting for rolled-back jobs.
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
    class TemporalAdapter < ActiveJob::QueueAdapters::AbstractAdapter
      # @return [WorkflowEnqueuer] the enqueuer service
      attr_reader :enqueuer

      # Initialize the adapter with a WorkflowEnqueuer service instance.
      def initialize
        super

        config = ActiveJob::Temporal.config
        logger = config.logger

        @enqueuer = ActiveJob::Temporal::WorkflowEnqueuer.new(
          -> { ActiveJob::Temporal.client },
          config,
          logger
        )
      end

      # Enqueues a job for immediate execution on Temporal by starting the AjWorkflow.
      #
      # Delegates to the WorkflowEnqueuer service to handle the mechanics of workflow
      # creation and startup.
      #
      # @param job [ActiveJob::Base] the job instance provided by ActiveJob
      # @return [Object] workflow run handle if provided by Temporal SDK
      #
      # @raise [ActiveJob::SerializationError] if payload serialization fails or exceeds max_payload_size_kb
      # @raise [ActiveJob::EnqueueError] if the Temporal client cannot start the workflow
      # @raise [ActiveJob::Temporal::ConfigurationError] if configuration is invalid
      #
      # @note FAIL Conflict Policy
      #   Duplicate job_id values raise DuplicateEnqueueError. ActiveJob catches
      #   this as an enqueue failure, so `perform_later` returns false and the
      #   yielded job exposes the error through `enqueue_error`.
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
        @enqueuer.enqueue(job)
      end

      # Enqueues a job for execution at a specific time by starting the AjWorkflow immediately.
      #
      # The workflow starts immediately but sleeps (non-blockingly) until the scheduled time
      # before executing the activity. This leverages Temporal's durable timers.
      #
      # @param job [ActiveJob::Base] the job instance provided by ActiveJob
      # @param timestamp [Integer, Float] UNIX timestamp when the job should be executed
      # @return [Object] workflow run handle if provided by Temporal SDK
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
        @enqueuer.enqueue(job, scheduled_at: scheduled_time)
      end

      # Signals transaction-aware ActiveJob versions to defer enqueuing until after commit.
      #
      # Rails 8 uses the job class `enqueue_after_transaction_commit` setting instead. The
      # TransactionSafety hook enables that setting when a job selects the Temporal adapter.
      # This method remains for adapter-contract compatibility with older ActiveJob behavior.
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
    end
  end
end
