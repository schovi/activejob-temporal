# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Cancel
      class << self
        # Cancels a running Temporal workflow by sending a cancellation request.
        # This method first queries Temporal to determine the workflow state before
        # attempting cancellation.
        #
        # @param job_class [Class] The ActiveJob class for the job to cancel.
        # @param job_id [String] Identifier of the job to cancel.
        # @return [Boolean, nil] Returns false if workflow already completed, nil if cancelled successfully
        #
        # @raise [WorkflowNotFoundError] if no workflow exists for the given job_id
        # @raise [TemporalConnectionError] if the Temporal cluster cannot be reached
        #
        # @example Cancel a running job
        #   ActiveJob::Temporal.cancel(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
        def cancel(job_class, job_id)
          workflow_id = build_workflow_id(job_class, job_id)
          client = ActiveJob::Temporal.client
          workflow_state = find_workflow(client, job_class, job_id)

          case workflow_state
          when :closed
            log_workflow_already_completed(job_class, job_id, workflow_id)
            false
          when :not_found
            raise WorkflowNotFoundError,
                  "No workflow found for job_id #{job_id}. The job may have never existed."
          when :running
            client.workflow_handle(workflow_id).cancel
            log_cancellation_requested(job_class, job_id, workflow_id)
          end
        end

        private

        def build_workflow_id(job_class, job_id)
          "ajwf:#{job_class.name}:#{job_id}"
        end

        # Queries Temporal to determine the current state of the workflow.
        # Checks running workflows first, then closed workflows.
        #
        # @param client [Temporalio::Client] The Temporal client instance
        # @param _job_class [Class] The ActiveJob class (unused, kept for future extensibility)
        # @param job_id [String] The job identifier
        # @return [Symbol] :running, :closed, or :not_found
        # @raise [TemporalConnectionError] if connection to Temporal fails
        def find_workflow(client, _job_class, job_id)
          # Query running workflows first
          running_query = running_workflows_query(job_id)
          running = client.list_workflows(query: running_query).first
          return :running if running

          # Query closed workflows (completed, failed, cancelled, etc.)
          closed_query = closed_workflows_query(job_id)
          closed = client.list_workflows(query: closed_query).first
          return :closed if closed

          :not_found
        rescue StandardError => e
          raise TemporalConnectionError,
                "Failed to query Temporal workflows for job_id #{job_id}: #{e.message}"
        end

        def running_workflows_query(job_id)
          "ajJobId='#{job_id}' AND ExecutionStatus='Running'"
        end

        def closed_workflows_query(job_id)
          "ajJobId='#{job_id}' AND ExecutionStatus IN ('Completed', 'Failed', 'Cancelled', " \
            "'Terminated', 'TimedOut', 'ContinuedAsNew')"
        end

        def log_cancellation_requested(job_class, job_id, workflow_id)
          ActiveJob::Temporal::Logger.info(
            "cancellation_requested",
            workflow_id: workflow_id,
            job_class: job_class.name,
            job_id: job_id
          )
        end

        def log_workflow_already_completed(job_class, job_id, workflow_id)
          ActiveJob::Temporal::Logger.warn(
            "cancellation_workflow_already_completed",
            workflow_id: workflow_id,
            job_class: job_class.name,
            job_id: job_id,
            status: "completed"
          )
        end
      end
    end
  end
end
