# frozen_string_literal: true

require "time"

require_relative "dead_letter_payload_validation"
require_relative "job_payload_builder"
require_relative "workflow_id_builder"

module ActiveJob
  module Temporal
    # Service object for enqueueing jobs as Temporal workflows.
    #
    # This class handles the mechanics of converting an ActiveJob into a Temporal workflow
    # execution, including payload serialization, workflow ID generation, and options building.
    #
    # @example Using with a job
    #   enqueuer = WorkflowEnqueuer.new(client, config)
    #   workflow_id = enqueuer.enqueue(job, scheduled_at: 5.minutes.from_now)
    #
    # @example Direct usage
    #   client = ActiveJob::Temporal.client
    #   config = ActiveJob::Temporal.config
    #   enqueuer = WorkflowEnqueuer.new(client, config)
    #   enqueuer.enqueue(job)
    class WorkflowEnqueuer
      # @param client [Temporalio::Client] Temporal client connection
      # @param config [ActiveJob::Temporal::Configuration] Configuration object
      # @param logger [Logger] Optional logger instance
      # @param workflow_id_builder [WorkflowIdBuilder] Builder for Temporal workflow IDs
      def initialize(client, config, logger = nil, workflow_id_builder: nil, payload_builder: nil)
        @client_provider = client if client.respond_to?(:call)
        @client = client unless @client_provider
        @config = config
        @logger = logger || config.logger
        @workflow_id_builder = workflow_id_builder || WorkflowIdBuilder.new(configured_workflow_id_generator)
        @payload_builder = payload_builder || JobPayloadBuilder.new(config)
      end

      # Enqueue a job as a Temporal workflow.
      #
      # Performs validation, builds the payload, generates a workflow ID, constructs
      # workflow options, and starts the workflow via the Temporal client.
      #
      # @param job [ActiveJob::Base] The job to enqueue
      # @param scheduled_at [Time, nil] Time to schedule job, nil for immediate execution
      # @return [Object, nil] Workflow run handle (or nil if duplicate job_id)
      #
      # @raise [ActiveJob::SerializationError] If payload serialization fails or exceeds max size
      # @raise [ActiveJob::EnqueueError] If workflow cannot be started
      # @raise [ActiveJob::Temporal::ConfigurationError] If job configuration is invalid
      #
      # @example Immediate execution
      #   enqueuer.enqueue(job) # => workflow handle
      #
      # @example Scheduled execution
      #   enqueuer.enqueue(job, scheduled_at: 1.hour.from_now) # => workflow handle
      #
      # @example Duplicate job (FAIL conflict policy)
      #   enqueuer.enqueue(job) # => handle
      #   enqueuer.enqueue(job) # => nil (FAIL conflict returns nil)
      def enqueue(job, scheduled_at: nil)
        validate_job_for_enqueueing(job)
        scheduled_at = validate_scheduled_at!(scheduled_at)
        workflow_id = @workflow_id_builder.build(job)
        payload = build_payload(job, workflow_id: workflow_id, scheduled_at: scheduled_at)
        enqueue_with_payload(job, payload, workflow_id)
      end

      private

      def configured_workflow_id_generator
        return unless @config.respond_to?(:workflow_id_generator)

        @config.workflow_id_generator
      end

      # Enqueues a workflow with the given payload and options.
      # @api private
      def enqueue_with_payload(job, payload, workflow_id)
        DeadLetterPayloadValidation.validate!(payload)

        task_queue = Adapter.resolve_task_queue(job, config: @config)
        add_dead_letter_task_queue(payload, task_queue)

        options = {
          id: workflow_id,
          task_queue: task_queue,
          id_conflict_policy: Temporalio::WorkflowIDConflictPolicy::FAIL
        }

        # Add search attributes if configured
        if @config.respond_to?(:enable_search_attributes) && @config.enable_search_attributes
          search_attributes = SearchAttributes.for(job)
          options[:search_attributes] = search_attributes
        end

        start_workflow(job, payload, options)
      end

      def add_dead_letter_task_queue(payload, task_queue)
        dead_letter = payload[:dead_letter] || payload["dead_letter"]
        return unless dead_letter

        dead_letter[:task_queue] = task_queue if dead_letter.key?(:queue)
        dead_letter["task_queue"] = task_queue if dead_letter.key?("queue")
      end

      # Builds a payload hash from a job instance.
      # Includes the job's retry policy and temporal timeout options for use in the workflow.
      # @api private
      def build_payload(job, workflow_id:, scheduled_at: nil)
        @payload_builder.build(
          job,
          scheduled_at: scheduled_at,
          encryption_context: encryption_context_for(workflow_id)
        )
      end

      def encryption_context_for(workflow_id)
        { namespace: @config.namespace, workflow_id: workflow_id }
      end

      # Starts the Temporal workflow with the given options.
      # @api private
      def start_workflow(job, payload, options)
        workflow_class = Workflows::AjWorkflow
        handle = client.start_workflow(workflow_class, payload, **options)

        log_enqueued(job, options, payload, duplicate: false)

        handle
      rescue StandardError => e
        if workflow_already_started?(e)
          log_enqueued(job, options, payload, duplicate: true)
          return nil
        end

        raise ActiveJob::EnqueueError, build_enqueue_error_message(job, e)
      end

      # Checks if error indicates workflow was already started (duplicate job_id).
      # @api private
      def workflow_already_started?(error)
        return true if defined?(Temporalio::Error::WorkflowAlreadyStartedError) &&
                       error.is_a?(Temporalio::Error::WorkflowAlreadyStartedError)
        return true if defined?(Temporalio::Client::WorkflowAlreadyStartedError) &&
                       error.is_a?(Temporalio::Client::WorkflowAlreadyStartedError)

        defined?(Temporalio::Error::RPCError::Code::ALREADY_EXISTS) &&
          error.respond_to?(:code) &&
          error.code == Temporalio::Error::RPCError::Code::ALREADY_EXISTS
      end

      # Logs enqueue event with structured metadata.
      # @api private
      def log_enqueued(job, options, payload, duplicate:)
        attributes = {
          workflow_id: options[:id],
          job_class: job.class.name,
          job_id: job.job_id,
          queue: job.queue_name,
          task_queue: options[:task_queue],
          duplicate: duplicate
        }
        attributes[:scheduled_at] = payload[:scheduled_at] if payload[:scheduled_at]

        Logger.log_event("workflow_enqueued", **attributes)
        AuditLog.record("job.enqueued", attributes)
        Metrics.record_enqueue(job: job, duplicate: duplicate)
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

      def client
        return @client_provider.call if @client_provider

        @client
      end

      # Validate job before enqueueing.
      #
      # @param job [ActiveJob::Base]
      # @raise [ActiveJob::Temporal::ConfigurationError] If job configuration is invalid
      # @api private
      def validate_job_for_enqueueing(job)
        raise ConfigurationError, "Job queue name cannot be blank" if job.queue_name.blank?
      end

      def validate_scheduled_at!(scheduled_at)
        return if scheduled_at.nil?

        scheduled_time = coerce_scheduled_at!(scheduled_at)
        raise ArgumentError, "scheduled_at must be in the future" unless scheduled_time > Time.now

        scheduled_time
      end

      def coerce_scheduled_at!(scheduled_at)
        scheduled_time = scheduled_at.is_a?(String) ? Time.iso8601(scheduled_at) : scheduled_at
        scheduled_time = scheduled_time.to_time if !scheduled_time.is_a?(Time) && scheduled_time.respond_to?(:to_time)
        raise ArgumentError unless scheduled_time.is_a?(Time)

        scheduled_time
      rescue ArgumentError, TypeError
        raise ArgumentError, "scheduled_at must be an ISO8601 string or respond to to_time"
      end
    end
  end
end
