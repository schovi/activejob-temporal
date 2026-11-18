# frozen_string_literal: true

require "time"

require_relative "dead_letter_payload_validation"
require_relative "job_payload_builder"
require_relative "observability"
require_relative "workflow_enqueuer_batch"
require_relative "standalone_activity"
require_relative "workflow_id_builder"
require_relative "workflow_types"

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
    # rubocop:disable-next Metrics/ClassLength
    class WorkflowEnqueuer
      include WorkflowEnqueuerBatch

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
      # @return [Object] Workflow run handle
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
      #   enqueuer.enqueue(job) # raises DuplicateEnqueueError
      def enqueue(job, scheduled_at: nil)
        validate_job_for_enqueueing(job)
        scheduled_at = validate_scheduled_at!(scheduled_at)
        return enqueue_standalone(job, scheduled_at) if StandaloneActivity.enabled?(job.class)

        workflow_id = @workflow_id_builder.build(job)
        payload = build_payload(job, workflow_id: workflow_id, scheduled_at: scheduled_at)
        enqueue_with_payload(job, payload, workflow_id)
      end

      private

      def enqueue_standalone(job, scheduled_at)
        temporal_client = client
        unless temporal_client.respond_to?(:start_activity)
          raise ConfigurationError, "standalone activities require temporalio >= 1.5"
        end

        require_relative "activities/aj_runner_activity"

        activity_id = WorkflowIdBuilder.default_for(job)
        WorkflowIdBuilder.validate!(activity_id)
        payload = @payload_builder.build(
          job, scheduled_at: scheduled_at, encryption_context: encryption_context_for(activity_id), standalone: true
        )
        options = start_options(job, activity_id).merge(@payload_builder.standalone_activity_options(job))
        options[:start_delay] = [scheduled_at - Time.now, 0].max if scheduled_at
        if defined?(Temporalio::ActivityIDConflictPolicy::FAIL)
          options[:id_conflict_policy] = Temporalio::ActivityIDConflictPolicy::FAIL
        end

        start_execution(job, payload, options, standalone: true) do
          temporal_client.start_activity(Activities::AjRunnerActivity, payload, **options)
        end
      end

      def configured_workflow_id_generator
        return unless @config.respond_to?(:workflow_id_generator)

        @config.workflow_id_generator
      end

      # Enqueues a workflow with the given payload and options.
      # @api private
      def enqueue_with_payload(job, payload, workflow_id)
        DeadLetterPayloadValidation.validate!(payload)

        options = start_options(job, workflow_id)
        options[:id_conflict_policy] = Temporalio::WorkflowIDConflictPolicy::FAIL
        add_dead_letter_task_queue(payload, options.fetch(:task_queue))

        start_execution(job, payload, options) do
          client.start_workflow(WorkflowTypes::ACTIVE_JOB, payload, **options)
        end
      end

      def start_options(job, id)
        options = { id: id, task_queue: Adapter.resolve_task_queue(job, config: @config) }
        priority = Adapter.resolve_priority(job, config: @config)
        options[:priority] = priority if priority

        # Add search attributes if configured
        if @config.respond_to?(:enable_search_attributes) && @config.enable_search_attributes
          search_attributes = SearchAttributes.for(job)
          options[:search_attributes] = search_attributes
        end

        options
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

      def start_execution(job, payload, options, standalone: nil)
        handle = yield
      rescue StandardError => e
        if execution_already_started?(e)
          log_enqueued(job, options, payload, duplicate: true, standalone: standalone)
          raise DuplicateEnqueueError, build_duplicate_enqueue_error_message(job, options, standalone: standalone)
        end

        raise ActiveJob::EnqueueError.new(build_enqueue_error_message(job, e)), cause: e
      else
        log_enqueued(job, options, payload, duplicate: false, standalone: standalone)
        handle
      end

      # Checks if error indicates workflow was already started (duplicate job_id).
      # @api private
      def execution_already_started?(error)
        return true if defined?(Temporalio::Error::ActivityAlreadyStartedError) &&
                       error.is_a?(Temporalio::Error::ActivityAlreadyStartedError)
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
      def log_enqueued(job, options, payload, duplicate:, standalone:)
        attributes = enqueue_attributes(job, options, payload, duplicate: duplicate)

        attributes[:standalone] = true if standalone

        emit_enqueue_side_effect("log", attributes) do
          Logger.log_event("workflow_enqueued", **attributes)
        end
        emit_enqueue_side_effect("audit", attributes) do
          AuditLog.record("job.enqueued", attributes)
        end
        emit_enqueue_side_effect("observability", attributes) do
          Observability.emit(
            :enqueue,
            Observability.attributes_from_job(
              job,
              workflow_id: options[:id],
              task_queue: options[:task_queue],
              duplicate: duplicate,
              standalone: standalone
            )
          )
        end
      end

      def enqueue_attributes(job, options, payload, duplicate:)
        priority = options[:priority]
        attributes = {
          workflow_id: options[:id],
          job_class: job.class.name,
          job_id: job.job_id,
          queue: job.queue_name,
          task_queue: options[:task_queue],
          duplicate: duplicate
        }
        attributes[:scheduled_at] = payload[:scheduled_at] if payload[:scheduled_at]

        attributes.merge({ priority_key: priority&.priority_key, fairness_key: priority&.fairness_key }.compact)
      end

      def emit_enqueue_side_effect(side_effect, attributes)
        yield
      rescue StandardError => e
        report_enqueue_side_effect_failure(side_effect, attributes, e)
      end

      def report_enqueue_side_effect_failure(side_effect, attributes, error)
        Logger.warn(
          "workflow_enqueue_side_effect_failed",
          attributes.merge(side_effect: side_effect, error_class: error.class.name)
        )
      rescue StandardError
        nil
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

      def build_duplicate_enqueue_error_message(job, options, standalone:)
        format(
          "Job %<job_class>s (%<job_id>s) was already enqueued as %<kind>s %<workflow_id>s",
          job_class: job.class.name,
          job_id: job.job_id,
          workflow_id: options[:id],
          kind: standalone ? "standalone activity" : "workflow"
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
        return if scheduled_time <= Time.now

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
