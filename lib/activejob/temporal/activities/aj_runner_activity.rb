# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
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
      #   Job implementations MUST be idempotent. This activity sets a thread-local
      #   idempotency key (`Thread.current[:aj_temporal_idempotency_key]`) derived from
      #   the workflow ID to assist with idempotent external operations (e.g., API requests).
      #
      # @note Thread-Local Idempotency Key
      #   Jobs can access `Thread.current[:aj_temporal_idempotency_key]` to generate
      #   unique idempotency tokens for external API calls. The key format is
      #   "workflow_id/runner" and persists across retries for the same workflow execution.
      #
      # @note Exception Handling
      #   If the job raises an exception that matches a `discard_on` declaration,
      #   the activity raises a non-retryable `ApplicationError` to stop retries.
      #   Otherwise, the exception propagates and Temporal applies the retry policy.
      #
      # @example Activity execution flow
      #   1. Deserialize job arguments from payload
      #   2. Constantize job class
      #   3. Set thread-local idempotency key
      #   4. Instantiate job and call `perform(*args)`
      #   5. Handle exceptions (discard vs. retry)
      #   6. Clear idempotency key
      #
      # @example Using idempotency key in a job
      #   class ChargeCustomerJob < ApplicationJob
      #     def perform(customer_id, amount)
      #       idempotency_key = Thread.current[:aj_temporal_idempotency_key]
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
      class AjRunnerActivity < Temporalio::Activity::Definition
        # Thread-local key for storing the idempotency token.
        IDEMPOTENCY_KEY = :aj_temporal_idempotency_key

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
        #       key = Thread.current[:aj_temporal_idempotency_key]
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
        def execute(payload)
          job_class = nil

          args = Payload.deserialize_args(payload)
          job_class = constantize_job_class(payload)
          job = job_class.new

          set_idempotency_key
          perform_job(job, args)
        rescue StandardError => e
          handle_exception(job_class, e)
        ensure
          Thread.current[IDEMPOTENCY_KEY] = nil
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

        # Sets thread-local idempotency key from workflow ID.
        # @api private
        def set_idempotency_key
          workflow_id = if defined?(Temporalio::Activity::Context) && Temporalio::Activity::Context.exist?
                          Temporalio::Activity::Context.current.info.workflow_id
                        else
                          "unknown-workflow"
                        end
          Thread.current[IDEMPOTENCY_KEY] = "#{workflow_id}/runner"
        end

        # Handles exceptions by checking discard_on declarations.
        # @api private
        def handle_exception(job_class, error)
          if job_class && RetryMapper.discard_exception?(job_class, error)
            raise Temporalio::Error::ApplicationError.new(
              error.message,
              non_retryable: true
            )
          end

          raise error
        end
      end
    end
  end
end
