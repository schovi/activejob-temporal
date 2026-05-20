# frozen_string_literal: true

module ActiveJob
  module Temporal
    # Builds deterministic Temporal workflow IDs for ActiveJob jobs.
    #
    # The default format keeps workflow IDs stable across enqueue retries so
    # Temporal can reject duplicate starts for the same ActiveJob job_id.
    class WorkflowIdBuilder
      DEFAULT_PREFIX = "ajwf"

      # @param strategy [#call, nil] Optional callable that receives the job and returns a workflow ID
      def initialize(strategy = nil)
        @strategy = strategy
      end

      # Builds a workflow ID from an ActiveJob instance.
      #
      # @param job [ActiveJob::Base] ActiveJob instance being enqueued
      # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
      def build(job)
        return @strategy.call(job) if @strategy

        build_from_job_class(job.class, job.job_id)
      end

      # Builds a workflow ID from a job class and job ID.
      #
      # @param job_class [Class] ActiveJob class
      # @param job_id [String] ActiveJob job_id
      # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
      def build_from_job_class(job_class, job_id)
        "#{DEFAULT_PREFIX}:#{job_class.name}:#{job_id}"
      end
    end
  end
end
