# frozen_string_literal: true

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
      def initialize(client, config, logger = nil)
        @client = client
        @config = config
        @logger = logger || config.logger
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
        payload = build_payload(job, scheduled_at: scheduled_at)
        enqueue_with_payload(job, payload)
      end

      private

      # Enqueues a workflow with the given payload and options.
      # @api private
      def enqueue_with_payload(job, payload)
        workflow_id = Adapter.build_workflow_id(job)
        task_queue = Adapter.resolve_task_queue(job)

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

      # Builds a payload hash from a job instance.
      # Includes the job's retry policy for use in the workflow.
      # @api private
      def build_payload(job, scheduled_at: nil)
        payload = Payload.from_job(job, scheduled_at: scheduled_at)

        # Build and add retry policy from job class
        retry_policy = RetryMapper.for(job.class)
        payload[:retry_policy] = retry_policy

        payload
      end

      # Starts the Temporal workflow with the given options.
      # @api private
      def start_workflow(job, payload, options)
        workflow_class = Workflows::AjWorkflow
        handle = @client.start_workflow(workflow_class, payload, **options)

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
        return false unless defined?(Temporalio::Client::WorkflowAlreadyStartedError)

        error.is_a?(Temporalio::Client::WorkflowAlreadyStartedError)
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

      # Validate job before enqueueing.
      #
      # @param job [ActiveJob::Base]
      # @raise [ActiveJob::Temporal::ConfigurationError] If job configuration is invalid
      # @api private
      def validate_job_for_enqueueing(job)
        raise ConfigurationError, "Job queue name cannot be blank" if job.queue_name.blank?
      end
    end
  end
end
