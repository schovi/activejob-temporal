# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

require "activejob/temporal/payload"
require "activejob/temporal/retry_mapper"

# Provide lightweight Temporal stubs so specs can run without the real SDK.
unless defined?(Temporalio::Activity)
  module Temporalio
    module Activity
    end
  end
end

unless defined?(Temporalio::Activity::Definition)
  module Temporalio
    module Activity
      Definition = Class.new
    end
  end
end

unless defined?(Temporalio::Activity::ApplicationError)
  module Temporalio
    module Activity
      class ApplicationError < StandardError
        attr_reader :non_retryable, :cause

        def initialize(message = nil, non_retryable: false, cause: nil)
          super(message)
          @non_retryable = non_retryable
          @cause = cause
        end
      end
    end
  end
end

unless Temporalio::Activity.respond_to?(:info)
  module Temporalio
    module Activity
      Info = Struct.new(:workflow_id) unless const_defined?(:Info)

      class << self
        attr_writer :info

        def info
          @info ||= Info.new
        end
      end
    end
  end
end

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
      #   idempotency key (`aj_temporal_idempotency_key`) derived from the workflow ID
      #   to assist with idempotent external operations.
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
        # @raise [Temporalio::Activity::ApplicationError] if job raises a discardable exception
        # @raise [StandardError] if job raises a retryable exception (propagates to Temporal)
        #
        # @example Basic execution
        #   execute({
        #     job_class: "MyJob",
        #     job_id: "123",
        #     arguments: [{ "_aj_serialized" => "ActiveJob::Serializers::ObjectSerializer", "value" => {...} }]
        #   })
        def execute(payload)
          job_class = nil

          args = Payload.deserialize_args(payload)
          job_class = constantize_job_class(payload)
          job = job_class.new

          set_idempotency_key
          job.perform(*args)
        rescue StandardError => e
          handle_exception(job_class, e)
        ensure
          Thread.current[IDEMPOTENCY_KEY] = nil
        end

        private

        def constantize_job_class(payload)
          job_class_name = payload[:job_class] || payload["job_class"]
          raise ArgumentError, "payload missing job_class" unless job_class_name

          job_class_name.constantize
        end

        def set_idempotency_key
          workflow_id = if defined?(Temporalio::Activity::Context) && Temporalio::Activity::Context.exist?
                          Temporalio::Activity::Context.current.info.workflow_id
                        elsif Temporalio::Activity.respond_to?(:info)
                          # For unit tests with stub
                          Temporalio::Activity.info&.workflow_id || "unknown-workflow"
                        else
                          "unknown-workflow"
                        end
          Thread.current[IDEMPOTENCY_KEY] = "#{workflow_id}/runner"
        end

        def handle_exception(job_class, error)
          if job_class && RetryMapper.discard_exception?(job_class, error)
            raise Temporalio::Activity::ApplicationError.new(
              error.message,
              non_retryable: true,
              cause: error
            )
          end

          raise error
        end
      end
    end
  end
end
