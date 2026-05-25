# frozen_string_literal: true

require "temporalio/error"
require_relative "job_id_validation"
require_relative "visibility_query"
require_relative "workflow_id_builder"

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
      class CancellationRequest
        def initialize(client:, job_id:, workflow_id:, run_id: nil)
          @client = client
          @job_id = job_id
          @workflow_id = workflow_id
          @run_id = run_id
        end

        def call
          cancellation_handle.cancel
        rescue StandardError => e
          raise workflow_not_found_error, cause: e if rpc_not_found?(e)

          raise ActiveJob::Temporal::TemporalConnectionError.new(
            "Failed to cancel Temporal workflow for job_id #{@job_id}: #{e.message}"
          ), cause: e
        end

        private

        attr_reader :client, :workflow_id, :run_id

        def cancellation_handle
          return client.workflow_handle(workflow_id) unless run_id

          client.workflow_handle(workflow_id, run_id: run_id)
        end

        def workflow_not_found_error
          ActiveJob::Temporal::WorkflowNotFoundError.new(
            "No workflow found for job_id #{@job_id}. The job may have completed or never existed."
          )
        end

        def rpc_not_found?(error)
          defined?(Temporalio::Error::RPCError) &&
            error.is_a?(Temporalio::Error::RPCError) &&
            error.code == Temporalio::Error::RPCError::Code::NOT_FOUND
        end
      end
      private_constant :CancellationRequest

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
        # @raise [TemporalConnectionError] if Temporal lookup or cancellation RPCs fail
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
          validate_job_id!(job_id)
          client = ActiveJob::Temporal.client
          return nil if cancel_schedule_execution(client, job_class, job_id)

          workflow_state = find_workflow(client, job_class, job_id)
          workflow_id = workflow_state[:workflow_id]

          case workflow_state[:status]
          when :closed
            log_workflow_already_completed(job_class, job_id, workflow_id)
            false
          when :not_found
            raise ActiveJob::Temporal::WorkflowNotFoundError,
                  "No workflow found for job_id #{job_id}. The job may have never existed."
          when :running
            request_cancellation(client, job_id, workflow_id)
            log_cancellation_requested(job_class, job_id, workflow_id)
            log_audit_cancellation_requested(job_class, job_id, workflow_id)
            nil
          end
        end

        def cancel_all(job_class)
          validate_job_class!(job_class)

          cancel_where(ajClass: job_class.name)
        end

        def cancel_where(filters)
          BatchCanceller.new(ActiveJob::Temporal.client).cancel_where(filters)
        end

        private

        def validate_job_class!(job_class)
          return if job_class.respond_to?(:name) && !job_class.name.to_s.empty?

          raise ArgumentError, "job_class must be a named class"
        end

        # @param job_id [String] The job identifier to validate
        # @raise [ArgumentError] if job_id is not a safe string identifier
        # @api private
        def validate_job_id!(job_id)
          JobIdValidation.validate!(job_id)
        end

        def cancel_schedule_execution(client, job_class, job_id)
          schedule_reference = JobIdValidation.schedule_execution_reference(job_id)
          return false unless schedule_reference

          workflow_id = schedule_reference.fetch(:workflow_id)
          request_cancellation(client, job_id, workflow_id, run_id: schedule_reference.fetch(:run_id))
          log_cancellation_requested(job_class, job_id, workflow_id)
          log_audit_cancellation_requested(job_class, job_id, workflow_id)
          true
        rescue ActiveJob::Temporal::WorkflowNotFoundError
          false
        end

        def request_cancellation(client, job_id, workflow_id, run_id: nil)
          CancellationRequest.new(client: client, job_id: job_id, workflow_id: workflow_id, run_id: run_id).call
        end

        # Builds deterministic workflow ID from job class and job ID.
        # @api private
        def build_workflow_id(job_class, job_id)
          WorkflowIdBuilder.new.build_from_job_class(job_class, job_id)
        end

        # Queries Temporal to determine the current state of the workflow.
        # Checks running workflows first, then closed workflows.
        #
        # @param client [Temporalio::Client] The Temporal client instance
        # @param job_class [Class] The ActiveJob class for fallback workflow ID generation
        # @param job_id [String] The job identifier
        # @return [Symbol] :running, :closed, or :not_found
        # @raise [TemporalConnectionError] if connection to Temporal fails
        def find_workflow(client, job_class, job_id)
          # Query running workflows first
          running_query = running_workflows_query(job_class, job_id)
          running = client.list_workflows(running_query).first
          return workflow_state(:running, running, job_class, job_id) if running

          # Query closed workflows (completed, failed, cancelled, etc.)
          closed_query = closed_workflows_query(job_class, job_id)
          closed = client.list_workflows(closed_query).first
          return workflow_state(:closed, closed, job_class, job_id) if closed

          { status: :not_found, workflow_id: build_workflow_id(job_class, job_id) }
        rescue StandardError => e
          raise ActiveJob::Temporal::TemporalConnectionError,
                "Failed to query Temporal workflows for job_id #{job_id}: #{e.message}"
        end

        def workflow_state(status, workflow_info, job_class, job_id)
          workflow_id = if workflow_info.respond_to?(:id) && workflow_info.id
                          workflow_info.id
                        else
                          build_workflow_id(job_class, job_id)
                        end

          { status: status, workflow_id: workflow_id }
        end

        # @api private
        def running_workflows_query(job_class, job_id)
          workflow_search_query(job_class, job_id, "ExecutionStatus='Running'")
        end

        # @api private
        def closed_workflows_query(job_class, job_id)
          workflow_search_query(
            job_class,
            job_id,
            "ExecutionStatus IN ('Completed', 'Failed', 'Cancelled', 'Terminated', 'TimedOut', 'ContinuedAsNew')"
          )
        end

        def workflow_search_query(job_class, job_id, status_query)
          "ajClass=#{VisibilityQuery.quote(job_class.name)} AND ajJobId=#{VisibilityQuery.quote(job_id)} " \
            "AND #{status_query}"
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

        def log_audit_cancellation_requested(job_class, job_id, workflow_id)
          ActiveJob::Temporal::AuditLog.record(
            "job.cancelled",
            workflow_id: workflow_id,
            job_class: job_class.name,
            job_id: job_id,
            status: "requested"
          )
        end
      end
    end
  end
end

require_relative "cancel/batch_canceller"
