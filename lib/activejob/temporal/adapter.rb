# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Adapter
      module_function

      # Builds deterministic workflow ID used for Temporal workflows.
      # @param job [ActiveJob::Base] ActiveJob instance being enqueued
      # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
      def build_workflow_id(job)
        "ajwf:#{job.class.name}:#{job.job_id}"
      end
    end
  end
end
