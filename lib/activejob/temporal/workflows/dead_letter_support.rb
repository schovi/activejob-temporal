# frozen_string_literal: true

require "digest"
require "temporalio/error"
require "temporalio/workflow"

module ActiveJob
  module Temporal
    module Workflows
      module DeadLetterSupport
        private

        def dead_letterable_failure?(payload, error)
          metadata = dead_letter_metadata(payload)
          return false unless metadata
          return false unless job_execution_activity_failure?(error)

          return false unless error.retry_state == Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
          return true if dead_letter_queue_present?(metadata)

          log_dead_letter_skipped(metadata, error)
          false
        end

        def start_dead_letter_workflow(payload, error)
          metadata = dead_letter_metadata(payload)
          entry = dead_letter_entry(payload, error, metadata)

          Temporalio::Workflow.start_child_workflow(
            ActiveJob::Temporal::Workflows::DeadLetterWorkflow,
            entry,
            id: entry.fetch("id"),
            task_queue: metadata_value(metadata, :queue),
            parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON
          )
        end

        def dead_letter_entry(payload, error, metadata)
          {
            "id" => dead_letter_workflow_id(metadata),
            "state" => "pending",
            "payload" => payload,
            "failure" => failure_metadata(error),
            "metadata" => dead_letter_failure_metadata(metadata)
          }
        end

        def dead_letter_failure_metadata(metadata)
          job_class = metadata_value(metadata, :job_class)
          job_id = metadata_value(metadata, :job_id)
          {
            "job_class" => job_class,
            "job_id" => job_id,
            "original_queue_name" => metadata_value(metadata, :queue_name),
            "original_task_queue" => metadata_value(metadata, :task_queue) || metadata_value(metadata, :queue_name),
            "workflow_id" => workflow_id(job_class, job_id),
            "workflow_run_id" => workflow_run_id,
            "attempt" => metadata_value(metadata, :after_attempts),
            "max_attempts" => metadata_value(metadata, :after_attempts),
            "failed_at" => Temporalio::Workflow.now.iso8601
          }.compact
        end

        def failure_metadata(error)
          source_error = error.cause || error
          class_name = failure_class_name(source_error)
          {
            "class" => class_name,
            "message" => source_error.message.to_s,
            "retry_state" => error.retry_state,
            "fingerprint" => Digest::SHA256.hexdigest("#{class_name}:#{source_error.message}")
          }
        end

        def failure_class_name(error)
          type = error.type if error.is_a?(Temporalio::Error::ApplicationError)
          return type unless type.to_s.strip.empty?

          error.class.name
        end

        def dead_letter_workflow_id(metadata)
          "ajdlq:#{metadata_value(metadata, :job_class)}:#{metadata_value(metadata, :job_id)}"
        end

        def workflow_id(job_class, job_id)
          info = Temporalio::Workflow.info
          info.workflow_id if info.respond_to?(:workflow_id)
        rescue StandardError
          "ajwf:#{job_class}:#{job_id}"
        end

        def workflow_run_id
          info = Temporalio::Workflow.info
          info.run_id if info.respond_to?(:run_id)
        rescue StandardError
          nil
        end

        def dead_letter_metadata(payload)
          payload[:dead_letter] || payload["dead_letter"]
        end

        def job_execution_activity_failure?(error)
          error.respond_to?(:activity_type) && error.activity_type == "AjRunnerActivity"
        end

        def dead_letter_queue_present?(metadata)
          metadata_value(metadata, :queue).to_s.strip.present?
        end

        def log_dead_letter_skipped(metadata, error)
          Temporalio::Workflow.logger.warn(
            event: "dead_letter_skipped",
            reason: "blank_queue",
            job_class: metadata_value(metadata, :job_class),
            job_id: metadata_value(metadata, :job_id),
            queue_name: metadata_value(metadata, :queue_name),
            retry_state: error.retry_state
          )
        end

        def metadata_value(metadata, key)
          return unless metadata.respond_to?(:[])

          metadata[key] || metadata[key.to_s]
        rescue TypeError
          nil
        end
      end
    end
  end
end
