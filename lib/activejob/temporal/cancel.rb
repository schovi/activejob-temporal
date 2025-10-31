# frozen_string_literal: true

module ActiveJob
  module Temporal
    # Job cancellation with query-based workflow discovery.
    #
    # This module provides cancellation capabilities for ActiveJob workflows running on Temporal.
    # Cancellation is asynchronous and best-effort: workflows will stop only if they are actively
    # checking for cancellation signals (via heartbeating or cancellation checks).
    #
    # @note Best-Effort Semantics
    #   Temporal cancellation is cooperative, not forceful. Activities must check for cancellation
    #   by heartbeating or polling `Temporalio::Activity::Context.current.cancelled?`. Activities
    #   that do not check for cancellation will run to completion even after a cancel request.
    #
    # @note Query Strategy
    #   This module queries running workflows first, then closed workflows (completed, failed,
    #   cancelled, etc.) to determine the workflow state before issuing a cancellation request.
    #   This ensures idempotent cancellation behavior.
    #
    # @example Cancel a running job
    #   ActiveJob::Temporal.cancel(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
    #
    # @see https://docs.temporal.io/activities#heartbeat Temporal Activity Heartbeating
    # @see https://docs.temporal.io/workflows#cancellation Temporal Cancellation Guide
    module Cancel
      class << self
        # Cancels a running Temporal workflow by sending a cancellation request.
        #
        # This method first queries Temporal to determine the workflow state before
        # attempting cancellation. It will not cancel already-completed workflows.
        #
        # @param job_class [Class] The ActiveJob class for the job to cancel.
        # @param job_id [String] Identifier of the job to cancel.
        # @return [Boolean, nil] Returns false if workflow already completed, nil if cancellation requested
        #
        # @raise [WorkflowNotFoundError] if no workflow exists for the given job_id
        # @raise [TemporalConnectionError] if the Temporal cluster cannot be reached
        #
        # @note Asynchronous Cancellation
        #   Cancellation requests are asynchronous. The method returns immediately after
        #   sending the request. The workflow will stop only if it checks for cancellation.
        #
        # @example Cancel a running job
        #   result = ActiveJob::Temporal.cancel(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
        #   puts "Cancellation requested" if result.nil?
        #
        # @example Handle all outcomes
        #   begin
        #     result = ActiveJob::Temporal.cancel(MyJob, "abc-123")
        #     case result
        #     when false
        #       puts "Job already completed, cannot cancel"
        #     when nil
        #       puts "Cancellation sent to Temporal"
        #     end
        #   rescue ActiveJob::Temporal::WorkflowNotFoundError
        #     puts "Job never existed or already removed from history"
        #   rescue ActiveJob::Temporal::TemporalConnectionError => e
        #     puts "Cannot reach Temporal: #{e.message}"
        #   end
        #
        # @see #find_workflow
        def cancel(job_class, job_id)
          workflow_id = build_workflow_id(job_class, job_id)
          client = ActiveJob::Temporal.client
          workflow_state = find_workflow(client, job_class, job_id)

          case workflow_state
          when :closed
            log_workflow_already_completed(job_class, job_id, workflow_id)
            false
          when :not_found
            raise ActiveJob::Temporal::WorkflowNotFoundError,
                  "No workflow found for job_id #{job_id}. The job may have never existed."
          when :running
            client.workflow_handle(workflow_id).cancel
            log_cancellation_requested(job_class, job_id, workflow_id)
            nil
          end
        end

        private

        # Builds deterministic workflow ID from job class and job ID.
        # @api private
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
          raise ActiveJob::Temporal::TemporalConnectionError,
                "Failed to query Temporal workflows for job_id #{job_id}: #{e.message}"
        end

        # Builds Temporal query for running workflows by job_id.
        # @api private
        def running_workflows_query(job_id)
          "ajJobId='#{job_id}' AND ExecutionStatus='Running'"
        end

        # Builds Temporal query for closed workflows by job_id.
        # @api private
        def closed_workflows_query(job_id)
          "ajJobId='#{job_id}' AND ExecutionStatus IN ('Completed', 'Failed', 'Cancelled', " \
            "'Terminated', 'TimedOut', 'ContinuedAsNew')"
        end

        # Logs cancellation request event.
        # @api private
        def log_cancellation_requested(job_class, job_id, workflow_id)
          ActiveJob::Temporal::Logger.info(
            "cancellation_requested",
            workflow_id: workflow_id,
            job_class: job_class.name,
            job_id: job_id
          )
        end

        # Logs event when attempting to cancel an already-completed workflow.
        # @api private
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
