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
      # AjRunnerActivity hydrates and executes the job inside a Temporal activity.
      class AjRunnerActivity < Temporalio::Activity::Definition
        IDEMPOTENCY_KEY = :aj_temporal_idempotency_key

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
          workflow_id = Temporalio::Activity.info&.workflow_id || "unknown-workflow"
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
