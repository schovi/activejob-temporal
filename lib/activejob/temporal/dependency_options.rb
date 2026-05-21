# frozen_string_literal: true

require "active_job"
require_relative "workflow_id_builder"

module ActiveJob
  module Temporal
    module DependencyOptions
      JOB_CLASS_NAME_PATTERN = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/
      SAFE_ID_PATTERN = /\A[A-Za-z0-9_.:-]+\z/
      FAILURE_POLICIES = %i[fail ignore].freeze

      attr_reader :temporal_dependencies, :temporal_dependency_failure_policy

      def self.normalize(depends_on)
        dependencies = depends_on.is_a?(Array) ? depends_on : [depends_on]
        raise ArgumentError, "depends_on must contain at least one job dependency" if dependencies.empty?

        dependencies.map { |dependency| normalize_dependency(dependency) }
      end

      def self.normalize_failure_policy(policy)
        normalized_policy = policy.to_sym
        return normalized_policy if FAILURE_POLICIES.include?(normalized_policy)

        raise ArgumentError, "on_dependency_failure must be :fail or :ignore"
      rescue NoMethodError
        raise ArgumentError, "on_dependency_failure must be :fail or :ignore"
      end

      def self.normalize_dependency(dependency)
        return normalize_job_dependency(dependency) if dependency.is_a?(ActiveJob::Base)
        return normalize_hash_dependency(dependency) if dependency.is_a?(Hash)
        return { job_id: normalize_id(dependency, "job_id") } if dependency.is_a?(String)

        raise ArgumentError, "depends_on entries must be ActiveJob instances, job IDs, or dependency hashes"
      end
      private_class_method :normalize_dependency

      def self.normalize_job_dependency(job)
        {
          job_class: normalize_job_class(job.class),
          job_id: normalize_id(job.job_id, "job_id"),
          workflow_id: WorkflowIdBuilder.new(configured_workflow_id_generator).build(job)
        }
      end
      private_class_method :normalize_job_dependency

      def self.configured_workflow_id_generator
        ActiveJob::Temporal.config.workflow_id_generator if ActiveJob::Temporal.respond_to?(:config)
      end
      private_class_method :configured_workflow_id_generator

      def self.normalize_hash_dependency(dependency)
        normalized = {}
        job_id = hash_value(dependency, :job_id)
        workflow_id = hash_value(dependency, :workflow_id)
        job_class = hash_value(dependency, :job_class)

        normalized[:job_id] = normalize_id(job_id, "job_id") if job_id
        normalized[:workflow_id] = normalize_id(workflow_id, "workflow_id") if workflow_id
        normalized[:job_class] = normalize_job_class(job_class) if job_class

        if normalized[:job_id].nil? && normalized[:workflow_id].nil?
          raise ArgumentError, "dependency hashes must include job_id or workflow_id"
        end

        normalized
      end
      private_class_method :normalize_hash_dependency

      def self.normalize_job_class(job_class)
        name = if job_class.is_a?(Class) && job_class < ActiveJob::Base
                 job_class.name
               else
                 job_class.to_s
               end
        unless name.match?(JOB_CLASS_NAME_PATTERN)
          raise ArgumentError, "dependency job_class must be a named ActiveJob class or valid class name"
        end

        name
      end
      private_class_method :normalize_job_class

      def self.normalize_id(value, name)
        id = value.to_s
        raise ArgumentError, "dependency #{name} must not be blank" if id.strip.empty?
        raise ArgumentError, "dependency #{name} contains unsupported characters" unless id.match?(SAFE_ID_PATTERN)

        id
      end
      private_class_method :normalize_id

      def self.hash_value(hash, key)
        hash[key] || hash[key.to_s]
      end
      private_class_method :hash_value

      def set(options = {})
        enqueue_options = options.dup
        dependencies_configured = enqueue_options.key?(:depends_on)
        failure_policy_configured = enqueue_options.key?(:on_dependency_failure)

        normalized_dependencies = if dependencies_configured
                                    DependencyOptions.normalize(enqueue_options.delete(:depends_on))
                                  end
        normalized_failure_policy = normalize_dependency_failure_policy(
          enqueue_options.delete(:on_dependency_failure),
          failure_policy_configured
        )

        if failure_policy_configured && !dependencies_configured && normalized_dependencies.nil?
          raise ArgumentError, "on_dependency_failure requires depends_on"
        end

        super(enqueue_options).tap do
          @temporal_dependencies = normalized_dependencies if dependencies_configured
          @temporal_dependency_failure_policy = normalized_failure_policy || :fail if dependencies_configured
        end
      end

      private

      def normalize_dependency_failure_policy(policy, configured)
        return unless configured

        DependencyOptions.normalize_failure_policy(policy)
      end
    end
  end
end

ActiveJob::Base.prepend(ActiveJob::Temporal::DependencyOptions) if defined?(ActiveJob::Base)
