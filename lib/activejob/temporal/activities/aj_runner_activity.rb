# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "active_job"
require "time"
require "temporalio/activity"

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

        class RetryRequested < StandardError
          attr_reader :job, :options, :original_error

          def initialize(job, options)
            @job = job
            @options = options
            @original_error = options[:error] || options["error"]
            super(@original_error&.message || "ActiveJob retry requested")
          end
        end

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

          result = instrument_perform(deserialized_payload) do
            perform_deserialized_job(deserialized_payload, raw_arguments) do |resolved_job_class|
              job_class = resolved_job_class
            end
          end
          audit_completed(audit_context)
          Payload.delete_external_payload(payload)
          result
        rescue StandardError => e
          observed_error = observed_error_for(e)
          audit_failed(audit_context || empty_audit_context, observed_error)
          record_retry_observability(deserialized_payload || payload, observed_error)
          handle_exception(job_class, e)
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

        def perform_job(job)
          ActiveJob::Temporal.config.middleware_chain.call(job) do
            job.perform_now
          end
        end

        def perform_deserialized_job(payload, raw_arguments)
          job_data = active_job_data_for(payload, raw_arguments)
          job_class = constantize_job_class(job_data)
          yield job_class

          apply_activity_retry_state(job_data, job_class)
          job = deserialize_job(job_data)
          intercept_active_job_retry(job)

          set_idempotency_key
          perform_job(job)
        end

        def active_job_data_for(payload, raw_arguments)
          job_data = stringify_keys(payload[:active_job] || payload["active_job"] || legacy_active_job_data(payload))
          job_data["arguments"] = ActiveJob::Arguments.serialize(Array(raw_arguments)) unless raw_arguments.nil?
          job_data
        end

        def legacy_active_job_data(payload)
          {
            "job_class" => payload_value(payload, :job_class),
            "job_id" => payload_value(payload, :job_id),
            "provider_job_id" => payload_value(payload, :provider_job_id),
            "queue_name" => payload_value(payload, :queue_name),
            "priority" => payload_value(payload, :priority),
            "arguments" => payload_value(payload, :arguments) || [],
            "executions" => payload_value(payload, :executions) || 0,
            "exception_executions" => payload_value(payload, :exception_executions) || {},
            "locale" => payload_value(payload, :locale) || default_locale,
            "timezone" => payload_value(payload, :timezone) || default_timezone,
            "enqueued_at" => payload_value(payload, :enqueued_at) || Time.now.utc.iso8601,
            "scheduled_at" => payload_value(payload, :scheduled_at)
          }.compact
        end

        def deserialize_job(job_data)
          ActiveJob::Base.deserialize(job_data)
        end

        def intercept_active_job_retry(job)
          job.define_singleton_method(:retry_job) do |options = {}|
            raise RetryRequested.new(self, options)
          end
        end

        def apply_activity_retry_state(job_data, job_class)
          previous_attempts = activity_attempt - 1
          return if previous_attempts <= 0

          job_data["executions"] = [integer_or_zero(job_data["executions"]), previous_attempts].max
          exception_executions = stringify_keys(job_data["exception_executions"] || {})
          RetryMapper.exception_execution_keys(job_class).each do |key|
            exception_executions[key] = [integer_or_zero(exception_executions[key]), previous_attempts].max
          end
          job_data["exception_executions"] = exception_executions
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
          raise retryable_application_error(error) if error.is_a?(RetryRequested)

          raise non_retryable_application_error(error) if job_class.nil? && deserialization_error?(error)

          raise non_retryable_application_error(error) if job_class && retry_attempts_exhausted?(job_class, error)

          raise non_retryable_application_error(error) if job_class && RetryMapper.discard_exception?(job_class, error)

          raise error
        end

        def observed_error_for(error)
          return error.original_error || error if error.is_a?(RetryRequested)

          error
        end

        def deserialization_error?(error)
          DESERIALIZATION_ERROR_CLASSES.any? { |error_class| error.is_a?(error_class) }
        end

        def retry_attempts_exhausted?(job_class, error)
          return false unless RetryMapper.retry_handler(job_class, error)

          maximum_attempts = RetryMapper.for(job_class, error)[:maximum_attempts]
          maximum_attempts.positive? && activity_attempt >= maximum_attempts
        end

        def retryable_application_error(retry_request)
          error = retry_request.original_error || retry_request
          options = { type: error.class.name }
          delay = retry_delay_seconds(retry_request.options[:wait] || retry_request.options["wait"])
          options[:next_retry_delay] = delay if delay

          Temporalio::Error::ApplicationError.new(error.message, **options)
        end

        def non_retryable_application_error(error)
          Temporalio::Error::ApplicationError.new(
            error.message,
            type: error.class.name,
            non_retryable: true
          )
        end

        def retry_delay_seconds(value)
          return unless value

          Float(value)
        rescue ArgumentError, TypeError
          nil
        end

        def activity_attempt
          return 1 unless defined?(Temporalio::Activity::Context) && Temporalio::Activity::Context.exist?

          info = Temporalio::Activity::Context.current.info
          return 1 unless info.respond_to?(:attempt)

          [Integer(info.attempt), 1].max
        rescue StandardError
          1
        end

        def integer_or_zero(value)
          Integer(value || 0)
        rescue ArgumentError, TypeError
          0
        end

        def payload_value(payload, key)
          payload[key] || payload[key.to_s]
        end

        def stringify_keys(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, child_value), normalized|
              normalized[key.to_s] = stringify_keys(child_value)
            end
          when Array
            value.map { |child_value| stringify_keys(child_value) }
          else
            value
          end
        end

        def default_locale
          I18n.locale.to_s if defined?(I18n)
        end

        def default_timezone
          Time.zone&.name if Time.respond_to?(:zone)
        end
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
