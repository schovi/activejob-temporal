# frozen_string_literal: true

require_relative "workflow_id_builder"

module ActiveJob
  module Temporal
    module JobPayloadDependencies
      private

      def apply_dependencies(payload, job)
        return unless job.respond_to?(:temporal_dependencies)

        dependencies = Array(job.temporal_dependencies)
        return if dependencies.empty?

        payload[:dependencies] = dependencies.map { |dependency| enrich_dependency(dependency) }
        policy = job.respond_to?(:temporal_dependency_failure_policy) ? job.temporal_dependency_failure_policy : :fail
        payload[:dependency_failure_policy] = policy.to_s
        payload[:dependency_wait] = dependency_wait_options(job)
      end

      def enrich_dependency(dependency)
        normalized = dependency.each_with_object({}) do |(key, value), enriched_dependency|
          enriched_dependency[key.to_sym] = value
        end
        normalized[:workflow_id] ||= default_dependency_workflow_id(normalized)
        normalized.compact
      end

      def default_dependency_workflow_id(dependency)
        job_class = dependency[:job_class]
        job_id = dependency[:job_id]
        return unless job_class && job_id

        workflow_id = "#{WorkflowIdBuilder::DEFAULT_PREFIX}:#{job_class}:#{job_id}"
        WorkflowIdBuilder.validate!(workflow_id)
        workflow_id
      end

      def dependency_wait_options(job)
        default_dependency_wait_options.merge(job_dependency_wait_options(job))
      end

      def default_dependency_wait_options
        {
          timeout: @config.dependency_wait_timeout.to_f,
          initial_interval: @config.dependency_wait_initial_interval.to_f,
          max_interval: @config.dependency_wait_max_interval.to_f,
          backoff: @config.dependency_wait_backoff.to_f
        }
      end

      def job_dependency_wait_options(job)
        return {} unless job.respond_to?(:temporal_dependency_wait)

        dependency_wait = job.temporal_dependency_wait
        return {} unless dependency_wait.is_a?(Hash)

        dependency_wait
      end
    end
  end
end
