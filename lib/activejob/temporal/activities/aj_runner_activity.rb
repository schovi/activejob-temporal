# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "temporalio/activity"

require_relative "best_effort_side_effects"
require_relative "../payload"
require_relative "../retry_mapper"

module ActiveJob
  module Temporal
    module Activities
      # Temporal activity that executes the actual ActiveJob logic.
      #
      # This activity hydrates the job class, deserializes arguments, and invokes
      # the job's `perform` method. It is the only place where side effects occur
      # (database writes, API calls, etc.).
      #
      # @note Idempotency and Retries
      #   Activities may be re-executed on transient failures due to Temporal's retry logic.
      #   Job implementations MUST be idempotent. This activity sets an execution-local
      #   idempotency key (`Fiber[:aj_temporal_idempotency_key]`) derived from the
      #   workflow ID to assist with idempotent external operations (e.g., API requests).
      #
      # @note Execution-Local Idempotency Key
      #   Jobs can access `Fiber[:aj_temporal_idempotency_key]` to generate unique
      #   idempotency tokens for external API calls. `Thread.current[...]` remains
      #   populated for existing synchronous jobs. The key format is "workflow_id/runner"
      #   and persists across retries for the same workflow execution.
      #
      # @note Exception Handling
      #   If the job raises an exception that matches a `discard_on` declaration,
      #   the activity raises a non-retryable `ApplicationError` to stop retries.
      #   Otherwise, the exception propagates and Temporal applies the retry policy.
      #
      # @example Activity execution flow
      #   1. Deserialize job arguments from payload
      #   2. Constantize job class
      #   3. Set execution-local idempotency key
      #   4. Instantiate job and call `perform(*args)`
      #   5. Handle exceptions (discard vs. retry)
      #   6. Clear idempotency key
      #
      # @example Using idempotency key in a job
      #   class ChargeCustomerJob < ApplicationJob
      #     def perform(customer_id, amount)
      #       idempotency_key = Fiber[:aj_temporal_idempotency_key]
      #       StripeAPI.charge(
      #         customer_id: customer_id,
      #         amount: amount,
      #         idempotency_key: idempotency_key
      #       )
      #     end
      #   end
      #
      # @see https://docs.temporal.io/activities Temporal Activities Guide
      # @see https://docs.temporal.io/retry-policies Temporal Retry Policies
      # rubocop:disable Metrics/ClassLength
      class AjRunnerActivity < Temporalio::Activity::Definition
        IDEMPOTENCY_KEY = :aj_temporal_idempotency_key
        DESERIALIZATION_ERROR_CLASSES = [
          ActiveJob::SerializationError,
          ActiveJob::DeserializationError
        ].freeze

        # Executes the job inside the Temporal activity context.
        #
        # @param payload [Hash] Job payload with serialized arguments and metadata
        # @option payload [String] :job_class Fully-qualified job class name (required)
        # @option payload [String] :job_id Unique job identifier
        # @option payload [Array] :arguments Serialized job arguments (via ActiveJob::Arguments)
        # @option payload [String] :queue_name Target queue name
        # @option payload [Integer] :executions Current execution count
        # @option payload [Hash] :exception_executions Exception execution counts
        #
        # @return [Object, nil] Result of the job's `perform` method (typically nil)
        #
        # @raise [ArgumentError] if payload is missing job_class
        # @raise [NameError] if job_class cannot be constantized
        # @raise [ActiveJob::SerializationError] if arguments cannot be deserialized
        # @raise [Temporalio::Error::ApplicationError] if job raises a discardable exception (non-retryable)
        # @raise [StandardError] if job raises a retryable exception (propagates to Temporal)
        #
        # @example Basic execution
        #   execute({
        #     job_class: "MyJob",
        #     job_id: "123",
        #     arguments: [{ "_aj_serialized" => "ActiveJob::Serializers::ObjectSerializer", "value" => {...} }]
        #   })
        #
        # @example Accessing idempotency key in job
        #   class MyJob < ApplicationJob
        #     def perform(user_id)
        #       key = Fiber[:aj_temporal_idempotency_key]
        #       ExternalAPI.create_user(user_id, idempotency_key: key)
        #     end
        #   end
        #
        # @example Handling discard_on exceptions
        #   class MyJob < ApplicationJob
        #     discard_on ActiveRecord::RecordNotFound
        #     def perform(user_id)
        #       User.find(user_id).do_something
        #     end
        #   end
        #   # If RecordNotFound is raised, activity raises non-retryable ApplicationError
        def execute(payload, raw_arguments = nil)
          job_class = nil
          audit_context = nil
          deserialized_payload = Payload.deserialize_payload(payload, encryption_context: activity_encryption_context)
          audit_context = audit_started(deserialized_payload)

          side_effects = BestEffortSideEffects.new(audit_context)
          result = perform_with_best_effort_observability(deserialized_payload, side_effects) do
            args = job_arguments(deserialized_payload, raw_arguments)
            job_class = constantize_job_class(deserialized_payload)
            set_idempotency_key
            perform_job(job_class.new, args)
          end
          record_success_side_effects(payload, audit_context, side_effects)
          result
        rescue StandardError => e
          handle_activity_error(e, job_class, audit_context, deserialized_payload || payload)
        ensure
          clear_idempotency_key
        end

        private

        # Constantizes job class from payload string.
        # @api private
        def constantize_job_class(payload)
          job_class_name = payload[:job_class] || payload["job_class"]
          raise ArgumentError, "payload missing job_class" unless job_class_name

          job_class_name.constantize
        end

        def perform_job(job, args)
          ActiveJob::Temporal.config.middleware_chain.call(job) do
            job.perform(*args)
          end
        end

        def job_arguments(payload, raw_arguments)
          raw_arguments.nil? ? Payload.deserialize_payload_args(payload) : Array(raw_arguments)
        end

        def perform_with_best_effort_observability(payload, side_effects)
          performed = false
          result = nil

          instrument_perform(payload) do
            result = yield
            performed = true
            result
          end

          result
        rescue StandardError => e
          raise unless performed

          side_effects.report_after_success("observability", e)
          result
        end

        def handle_activity_error(error, job_class, audit_context, retry_payload)
          failure_context = audit_context || empty_audit_context
          side_effects = BestEffortSideEffects.new(failure_context)
          side_effects.after_failure("audit") { audit_failed(failure_context, error) }
          side_effects.after_failure("retry_observability") do
            record_retry_observability(retry_payload, error)
          end
          handle_exception(job_class, error)
        end

        def instrument_perform(payload, &)
          Observability.instrument(:perform, Observability.attributes_from_payload(payload), &)
        end

        def record_retry_observability(payload, error)
          return unless Observability.retry_attempt?

          Observability.emit(
            :retry,
            Observability.attributes_from_payload(payload, error: error.class.name)
          )
        end

        def audit_started(payload)
          attributes = AuditLog.activity_attributes_from_payload(payload)
          AuditLog.record("job.started", attributes)

          { started_at: AuditLog.monotonic_time, attributes: attributes }
        end

        def audit_completed(audit_context)
          AuditLog.record(
            "job.completed",
            audit_context[:attributes].merge(duration_ms: audit_duration(audit_context))
          )
        end

        def record_success_side_effects(payload, audit_context, side_effects)
          side_effects.after_success("audit") { audit_completed(audit_context) }
          side_effects.after_success("external_payload_cleanup") do
            Payload.delete_external_payload(payload)
          end
        end

        def audit_failed(audit_context, error)
          cancelled = AuditLog.cancelled_error?(error)
          AuditLog.record(
            cancelled ? "job.cancelled" : "job.failed",
            audit_context[:attributes]
              .merge(duration_ms: audit_duration(audit_context))
              .merge(status: ("observed" if cancelled))
              .merge(AuditLog.error_attributes(error))
          )
        end

        def empty_audit_context
          { started_at: AuditLog.monotonic_time, attributes: {} }
        end

        def audit_duration(audit_context)
          AuditLog.elapsed_milliseconds(audit_context[:started_at])
        end

        # @api private
        def set_idempotency_key
          workflow_id = if defined?(Temporalio::Activity::Context) && Temporalio::Activity::Context.exist?
                          Temporalio::Activity::Context.current.info.workflow_id
                        else
                          "unknown-workflow"
                        end
          idempotency_key = "#{workflow_id}/runner"
          Thread.current[IDEMPOTENCY_KEY] = idempotency_key
          Fiber[IDEMPOTENCY_KEY] = idempotency_key
        end

        def clear_idempotency_key
          Thread.current[IDEMPOTENCY_KEY] = nil
          Fiber[IDEMPOTENCY_KEY] = nil
        end

        def activity_encryption_context
          return unless defined?(Temporalio::Activity::Context) && Temporalio::Activity::Context.exist?

          info = Temporalio::Activity::Context.current.info
          namespace = if info.respond_to?(:workflow_namespace)
                        info.workflow_namespace
                      else
                        ActiveJob::Temporal.config.namespace
                      end
          { namespace: namespace, workflow_id: info.workflow_id }
        end

        # Handles exceptions by checking discard_on declarations.
        # @api private
        def handle_exception(job_class, error)
          raise non_retryable_application_error(error) if job_class.nil? && deserialization_error?(error)

          raise non_retryable_application_error(error) if job_class && RetryMapper.discard_exception?(job_class, error)

          raise error
        end

        def deserialization_error?(error)
          DESERIALIZATION_ERROR_CLASSES.any? { |error_class| error.is_a?(error_class) }
        end

        def non_retryable_application_error(error)
          Temporalio::Error::ApplicationError.new(
            error.message,
            non_retryable: true
          )
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
