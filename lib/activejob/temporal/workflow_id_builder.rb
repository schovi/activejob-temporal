# frozen_string_literal: true

require_relative "configuration"

module ActiveJob
  module Temporal
    # Builds deterministic Temporal workflow IDs for ActiveJob jobs.
    #
    # The default format keeps workflow IDs stable across enqueue retries so
    # Temporal can reject duplicate starts for the same ActiveJob job_id.
    class WorkflowIdBuilder
      DEFAULT_PREFIX = "ajwf"
      MAX_WORKFLOW_ID_LENGTH = 255
      VALID_WORKFLOW_ID_PATTERN = /\A[A-Za-z0-9_.:-]+\z/

      # @param strategy [#call, nil] Optional callable that receives the job and returns a workflow ID
      def initialize(strategy = nil)
        @strategy = strategy || self.class.method(:default_for)
      end

      # Builds a workflow ID from an ActiveJob instance.
      #
      # @param job [ActiveJob::Base] ActiveJob instance being enqueued
      # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
      def build(job)
        workflow_id = call_strategy(job)
        self.class.validate!(workflow_id)
        workflow_id
      end

      # Builds a workflow ID from a job class and job ID.
      #
      # @param job_class [Class] ActiveJob class
      # @param job_id [String] ActiveJob job_id
      # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
      def build_from_job_class(job_class, job_id)
        workflow_id = self.class.default_from_job_class(job_class, job_id)
        self.class.validate!(workflow_id)
        workflow_id
      end

      class << self
        # Builds the default workflow ID for a job.
        #
        # @param job [ActiveJob::Base] ActiveJob instance being enqueued
        # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
        def default_for(job)
          default_from_job_class(job.class, job.job_id)
        end

        # Builds the default workflow ID from a job class and job ID.
        #
        # @param job_class [Class] ActiveJob class
        # @param job_id [String] ActiveJob job_id
        # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
        def default_from_job_class(job_class, job_id)
          "#{DEFAULT_PREFIX}:#{job_class.name}:#{job_id}"
        end

        # Validates generated workflow IDs before they reach Temporal.
        #
        # @param workflow_id [Object] generated workflow ID
        # @return [void]
        # @raise [ConfigurationError] when the generated ID is invalid
        def validate!(workflow_id)
          unless workflow_id.is_a?(String)
            raise ConfigurationError,
                  "workflow_id_generator must return a String, got #{workflow_id.class}: #{workflow_id.inspect}"
          end

          if workflow_id.empty?
            raise ConfigurationError, "workflow_id_generator returned an invalid workflow ID: must not be blank"
          end

          if workflow_id.length > MAX_WORKFLOW_ID_LENGTH
            raise ConfigurationError,
                  "workflow_id_generator returned an invalid workflow ID: maximum length is " \
                  "#{MAX_WORKFLOW_ID_LENGTH} characters (got #{workflow_id.length})"
          end

          return if workflow_id.match?(VALID_WORKFLOW_ID_PATTERN)

          raise ConfigurationError,
                "workflow_id_generator returned an invalid workflow ID: only letters, numbers, " \
                "underscore, hyphen, period, and colon are allowed (got #{workflow_id.inspect})"
        end
      end

      private

      def call_strategy(job)
        @strategy.call(job)
      rescue ArgumentError => e
        raise ConfigurationError,
              "workflow_id_generator must accept one ActiveJob argument: #{e.message}"
      end
    end
  end
end
