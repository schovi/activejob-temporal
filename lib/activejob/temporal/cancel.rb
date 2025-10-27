# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Cancel
      class << self
        # Cancels a running Temporal workflow by sending a cancellation request.
        # This is a best-effort operation; if the workflow already completed or
        # does not exist, the error is logged and suppressed.
        #
        # @param job_class [Class] The ActiveJob class for the job to cancel.
        # @param job_id [String] Identifier of the job to cancel.
        # @return [void]
        #
        # @raise [ActiveJob::Temporal::Error] if the Temporal cluster cannot be reached.
        #
        # @example Cancel a running job
        #   ActiveJob::Temporal.cancel(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
        def cancel(job_class, job_id)
          workflow_id = build_workflow_id(job_class, job_id)
          ActiveJob::Temporal.client.workflow_handle(workflow_id).cancel
          log_cancellation_requested(job_class, job_id, workflow_id)
        rescue StandardError => e
          return log_workflow_not_found(job_class, job_id, workflow_id, e) if workflow_not_found?(e)

          raise
        end

        private

        def build_workflow_id(job_class, job_id)
          "ajwf:#{job_class.name}:#{job_id}"
        end

        def workflow_not_found?(error)
          return false unless defined?(Temporalio::Error::RPCError)
          return false unless error.is_a?(Temporalio::Error::RPCError)

          not_found_code = if defined?(Temporalio::Error::RPCError::Code::NOT_FOUND)
                             Temporalio::Error::RPCError::Code::NOT_FOUND
                           else
                             5
                           end

          error.respond_to?(:code) && error.code == not_found_code
        end

        def log_cancellation_requested(job_class, job_id, workflow_id)
          ActiveJob::Temporal::Logger.log_event(
            "cancellation_requested",
            workflow_id: workflow_id,
            job_class: job_class.name,
            job_id: job_id
          )
        end

        def log_workflow_not_found(job_class, job_id, workflow_id, error)
          ActiveJob::Temporal::Logger.warn(
            "cancellation_workflow_not_found",
            workflow_id: workflow_id,
            job_class: job_class.name,
            job_id: job_id,
            error: error.message
          )
        end
      end
    end
  end
end
