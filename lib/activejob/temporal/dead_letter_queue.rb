# frozen_string_literal: true

require "temporalio/client"

require_relative "logger"

module ActiveJob
  module Temporal
    module DeadLetterQueue
      WORKFLOW_TYPE = "ActiveJobTemporalDeadLetterWorkflow"
      DEFAULT_ENTRIES_LIMIT = 100

      module_function

      def entry(job_class, job_id, run_id: nil, client: ActiveJob::Temporal.client)
        handle_for(job_class, job_id, run_id: run_id, client: client).query(:entry)
      end

      def entries(queue: nil, limit: DEFAULT_ENTRIES_LIMIT, client: ActiveJob::Temporal.client)
        validate_limit!(limit)

        client.list_workflows(entries_query(queue)).each_with_object([]) do |workflow, entries|
          entry = query_workflow_entry(client, workflow)
          entries << entry if entry
          break entries if entries.size >= limit
        end
      end

      def retry(job_class, job_id, queue: nil, client: ActiveJob::Temporal.client)
        handle = handle_for(job_class, job_id, client: client)
        entry = handle.query(:entry)
        if retried_entry?(entry)
          workflow_id = entry.fetch("retry_workflow_id")
          log_retry_requested(entry, workflow_id, queue, duplicate: true)
          return workflow_id
        end

        ensure_pending_entry!(entry)

        workflow_id = retry_workflow_id(entry)
        duplicate = start_retry_workflow(client, entry, workflow_id, queue)
        log_retry_requested(entry, workflow_id, queue, duplicate: duplicate)
        mark_retried_entry(handle, workflow_id)
        workflow_id
      end

      # rubocop:disable Naming/PredicateMethod
      def discard(job_class, job_id, reason: nil, client: ActiveJob::Temporal.client)
        handle_for(job_class, job_id, client: client).signal(:discard, reason)
        true
      end
      # rubocop:enable Naming/PredicateMethod

      def workflow_id(job_class, job_id)
        class_name = job_class.is_a?(Class) ? job_class.name : job_class.to_s
        "ajdlq:#{class_name}:#{job_id}"
      end

      def handle_for(job_class, job_id, run_id: nil, client: ActiveJob::Temporal.client)
        client.workflow_handle(workflow_id(job_class, job_id), run_id: run_id)
      end
      private_class_method :handle_for

      def entries_query(queue)
        query = ["WorkflowType='#{WORKFLOW_TYPE}'", "ExecutionStatus='Running'"]
        query << "TaskQueue='#{escape_query_value(queue)}'" if queue.to_s.strip.present?
        query.join(" AND ")
      end
      private_class_method :entries_query

      def query_workflow_entry(client, workflow)
        client.workflow_handle(workflow.id, run_id: workflow_run_id(workflow)).query(:entry)
      rescue Temporalio::Error
        nil
      end
      private_class_method :query_workflow_entry

      def start_retry_workflow(client, entry, workflow_id, queue)
        client.start_workflow(
          ActiveJob::Temporal::Workflows::AjWorkflow,
          retry_payload(entry),
          id: workflow_id,
          task_queue: retry_task_queue(entry, queue),
          id_conflict_policy: Temporalio::WorkflowIDConflictPolicy::FAIL
        )
        false
      rescue StandardError => e
        raise unless workflow_already_started?(e)

        true
      end
      private_class_method :start_retry_workflow

      def log_retry_requested(entry, workflow_id, queue, duplicate:)
        Logger.log_event(
          "dead_letter_retry_requested",
          {
            entry_id: entry.fetch("id"),
            workflow_id: workflow_id,
            job_class: entry.dig("payload", "job_class"),
            job_id: entry.dig("payload", "job_id"),
            task_queue: retry_task_queue(entry, queue),
            duplicate: duplicate
          }.compact
        )
      rescue StandardError
        nil
      end
      private_class_method :log_retry_requested

      def mark_retried_entry(handle, workflow_id)
        handle.signal(:mark_retried, workflow_id)
      rescue StandardError => e
        return if entry_retried_with_workflow_id?(query_entry_after_mark_failure(handle), workflow_id)

        message = "Retry workflow #{workflow_id} may be running, but could not mark dead letter entry retried"
        raise ActiveJob::Temporal::Error.new(message), cause: e
      end
      private_class_method :mark_retried_entry

      def query_entry_after_mark_failure(handle)
        handle.query(:entry)
      rescue StandardError
        nil
      end
      private_class_method :query_entry_after_mark_failure

      def ensure_pending_entry!(entry)
        state = entry.fetch("state", "pending")
        return if state == "pending"

        message = "Cannot retry dead letter entry #{entry.fetch('id')} with state #{state.inspect}"
        raise ActiveJob::Temporal::Error, message
      end
      private_class_method :ensure_pending_entry!

      def retried_entry?(entry)
        entry["state"] == "retried" && entry["retry_workflow_id"].to_s.strip.present?
      end
      private_class_method :retried_entry?

      def entry_retried_with_workflow_id?(entry, workflow_id)
        return false unless entry

        entry["state"] == "retried" && entry["retry_workflow_id"] == workflow_id
      end
      private_class_method :entry_retried_with_workflow_id?

      def retry_workflow_id(entry)
        "ajdlq-retry:#{entry.fetch('id')}"
      end
      private_class_method :retry_workflow_id

      def retry_payload(entry)
        entry.fetch("payload").reject { |key, _value| key.to_s == "scheduled_at" }
      end
      private_class_method :retry_payload

      def retry_task_queue(entry, queue)
        queue || entry.dig("metadata", "original_task_queue") || entry.dig("metadata", "original_queue_name")
      end
      private_class_method :retry_task_queue

      def workflow_run_id(workflow)
        workflow.respond_to?(:run_id) ? workflow.run_id : nil
      end
      private_class_method :workflow_run_id

      def validate_limit!(limit)
        return if limit.is_a?(Integer) && limit.positive?

        raise ArgumentError, "limit must be a positive integer"
      end
      private_class_method :validate_limit!

      def escape_query_value(value)
        value.to_s.gsub("'", "''")
      end
      private_class_method :escape_query_value

      def workflow_already_started?(error)
        (defined?(Temporalio::Error::WorkflowAlreadyStartedError) &&
          error.is_a?(Temporalio::Error::WorkflowAlreadyStartedError)) ||
          (defined?(Temporalio::Client::WorkflowAlreadyStartedError) &&
            error.is_a?(Temporalio::Client::WorkflowAlreadyStartedError)) ||
          (defined?(Temporalio::Error::RPCError::Code::ALREADY_EXISTS) &&
            error.respond_to?(:code) &&
            error.code == Temporalio::Error::RPCError::Code::ALREADY_EXISTS)
      end
      private_class_method :workflow_already_started?
    end
  end
end
