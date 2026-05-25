# frozen_string_literal: true

require_relative "workflow_id_builder"

module ActiveJob
  module Temporal
    module JobIdValidation
      MAX_JOB_ID_LENGTH = WorkflowIdBuilder::MAX_WORKFLOW_ID_LENGTH
      CONTROL_CHARACTER_PATTERN = WorkflowIdBuilder::CONTROL_CHARACTER_PATTERN
      SCHEDULE_WORKFLOW_ID_PREFIX = "ajschwf:"

      module_function

      def validate!(job_id)
        unless job_id.is_a?(String)
          raise ArgumentError, "job_id must be a String, got #{job_id.class}: #{job_id.inspect}"
        end

        raise ArgumentError, "job_id must be valid UTF-8" unless job_id.valid_encoding?
        raise ArgumentError, "job_id must not be blank" if job_id.strip.empty?

        if job_id.length > MAX_JOB_ID_LENGTH
          raise ArgumentError, "job_id maximum length is #{MAX_JOB_ID_LENGTH} characters (got #{job_id.length})"
        end

        return unless job_id.match?(CONTROL_CHARACTER_PATTERN)

        raise ArgumentError, "job_id control characters are not allowed (got #{job_id.inspect})"
      end

      def schedule_execution_reference(job_id)
        return unless job_id.start_with?(SCHEDULE_WORKFLOW_ID_PREFIX)

        workflow_id, separator, run_id = job_id.rpartition(":")
        return if separator.empty? || workflow_id.empty? || run_id.empty?

        { workflow_id: workflow_id, run_id: run_id }
      end
    end
  end
end
