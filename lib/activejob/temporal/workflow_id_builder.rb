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
      CONTROL_CHARACTER_PATTERN = /[[:cntrl:]]/

      # @param strategy [#call, nil] Optional callable that receives the job and returns a workflow ID
      def initialize(strategy = nil)
        @strategy = strategy
      end

      # Builds a workflow ID from an ActiveJob instance.
      #
      # @param job [ActiveJob::Base] ActiveJob instance being enqueued
      # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
      def build(job)
        workflow_id = class_configured_workflow_id(job) ||
                      configured_workflow_id(job) ||
                      self.class.default_for(job)
        self.class.validate!(workflow_id)
        workflow_id
      end

      # Builds a workflow ID from a job class and job ID.
      #
      # @param job_class [Class] ActiveJob class
      # @param job_id [String] ActiveJob job_id
      # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
      def build_from_job_class(job_class, job_id)
        workflow_id = self.class.prefixed_from_job_class(job_class, job_id) ||
                      self.class.default_from_job_class(job_class, job_id)
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

        def prefixed_from_job_class(job_class, job_id)
          prefix = workflow_id_prefix_for(job_class)
          return unless prefix

          "#{prefix}:#{job_id}"
        end

        def workflow_id_prefix_for(job_class)
          return unless job_class.respond_to?(:temporal_workflow_id_prefix)

          job_class.temporal_workflow_id_prefix
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

          unless utf8_compatible?(workflow_id)
            raise ConfigurationError,
                  "workflow_id_generator returned an invalid workflow ID: must be valid UTF-8"
          end

          if workflow_id.length > MAX_WORKFLOW_ID_LENGTH
            raise ConfigurationError,
                  "workflow_id_generator returned an invalid workflow ID: maximum length is " \
                  "#{MAX_WORKFLOW_ID_LENGTH} characters (got #{workflow_id.length})"
          end

          return unless workflow_id.match?(CONTROL_CHARACTER_PATTERN)

          raise ConfigurationError,
                "workflow_id_generator returned an invalid workflow ID: control characters are not allowed " \
                "(got #{workflow_id.inspect})"
        end

        private

        def utf8_compatible?(workflow_id)
          workflow_id.valid_encoding? && (workflow_id.encoding == Encoding::UTF_8 || workflow_id.ascii_only?)
        end
      end

      private

      def class_configured_workflow_id(job)
        prefix = self.class.workflow_id_prefix_for(job.class)
        return "#{prefix}:#{job.job_id}" if prefix

        strategy = class_workflow_id_strategy(job.class)
        return unless strategy

        call_class_strategy(strategy, job)
      end

      def class_workflow_id_strategy(job_class)
        return unless job_class.respond_to?(:temporal_workflow_id)

        job_class.temporal_workflow_id
      end

      def call_class_strategy(strategy, job)
        strategy.call(*Array(job.arguments))
      rescue ArgumentError => e
        raise ConfigurationError,
              "temporal_workflow_id block must accept this job's perform arguments: #{e.message}"
      end

      def configured_workflow_id(job)
        return unless @strategy

        call_strategy(job)
      end

      def call_strategy(job)
        @strategy.call(job)
      rescue ArgumentError => e
        raise ConfigurationError,
              "workflow_id_generator must accept one positional ActiveJob argument: #{e.message}"
      end
    end
  end
end
