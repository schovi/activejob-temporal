# frozen_string_literal: true

require "active_job"
require_relative "workflow_id_builder"

module ActiveJob
  module Temporal
    module DependencyOptions
      JOB_CLASS_NAME_PATTERN = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/
      SAFE_ID_PATTERN = /\A[A-Za-z0-9_.:-]+\z/
      FAILURE_POLICIES = %i[fail ignore].freeze
      WAIT_OPTION_KEYS = %i[timeout initial_interval max_interval backoff].freeze

      attr_reader :temporal_dependencies, :temporal_dependency_failure_policy, :temporal_dependency_wait

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

      def self.normalize_wait_options(options)
        raise ArgumentError, "dependency_wait must be a hash" unless options.is_a?(Hash)

        normalized = options.each_with_object({}) do |(key, value), wait_options|
          normalized_key = normalize_wait_option_key(key)
          wait_options[normalized_key] = normalize_wait_option_value(normalized_key, value)
        end
        validate_wait_interval_order!(normalized)
        normalized
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
        run_id = hash_value(dependency, :run_id)
        job_class = hash_value(dependency, :job_class)

        normalized[:job_id] = normalize_id(job_id, "job_id") if job_id
        normalized[:workflow_id] = normalize_id(workflow_id, "workflow_id") if workflow_id
        normalized[:run_id] = normalize_id(run_id, "run_id") if run_id
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

      def self.normalize_wait_option_key(key)
        normalized_key = key.to_sym
        return normalized_key if WAIT_OPTION_KEYS.include?(normalized_key)

        raise ArgumentError, "dependency_wait supports: #{WAIT_OPTION_KEYS.join(', ')}"
      rescue NoMethodError
        raise ArgumentError, "dependency_wait supports: #{WAIT_OPTION_KEYS.join(', ')}"
      end
      private_class_method :normalize_wait_option_key

      def self.normalize_wait_option_value(key, value)
        return normalize_wait_backoff(value) if key == :backoff

        normalize_wait_duration(value, key)
      end
      private_class_method :normalize_wait_option_value

      def self.normalize_wait_duration(value, key)
        unless value.is_a?(Numeric) || value.is_a?(ActiveSupport::Duration)
          raise ArgumentError, "dependency_wait #{key} must be a duration"
        end

        seconds = value.to_f
        raise ArgumentError, "dependency_wait #{key} must be positive" unless seconds.positive?

        seconds
      end
      private_class_method :normalize_wait_duration

      def self.normalize_wait_backoff(value)
        backoff = Float(value)
        raise ArgumentError, "dependency_wait backoff must be greater than or equal to 1" if backoff < 1.0

        backoff
      rescue ArgumentError, TypeError
        raise ArgumentError, "dependency_wait backoff must be greater than or equal to 1"
      end
      private_class_method :normalize_wait_backoff

      def self.validate_wait_interval_order!(wait_options)
        initial_interval = wait_options[:initial_interval]
        max_interval = wait_options[:max_interval]
        return unless initial_interval && max_interval
        return if max_interval >= initial_interval

        raise ArgumentError, "dependency_wait max_interval must be greater than or equal to initial_interval"
      end
      private_class_method :validate_wait_interval_order!

      def set(options = {})
        enqueue_options = options.dup
        dependency_options = normalize_dependency_set_options(enqueue_options)
        validate_dependency_set_options!(dependency_options)

        super(enqueue_options).tap do
          apply_dependency_set_options(dependency_options)
        end
      end

      private

      def normalize_dependency_set_options(enqueue_options)
        dependencies_configured = enqueue_options.key?(:depends_on)
        failure_policy_configured = enqueue_options.key?(:on_dependency_failure)
        dependency_wait_configured = enqueue_options.key?(:dependency_wait)

        {
          dependencies_configured: dependencies_configured,
          failure_policy_configured: failure_policy_configured,
          dependency_wait_configured: dependency_wait_configured,
          dependencies: normalize_dependencies(enqueue_options, dependencies_configured),
          failure_policy: normalize_dependency_failure_policy(
            enqueue_options.delete(:on_dependency_failure),
            failure_policy_configured
          ),
          dependency_wait: normalize_dependency_wait(enqueue_options, dependency_wait_configured)
        }
      end

      def normalize_dependencies(enqueue_options, configured)
        return unless configured

        DependencyOptions.normalize(enqueue_options.delete(:depends_on))
      end

      def normalize_dependency_wait(enqueue_options, configured)
        return unless configured

        DependencyOptions.normalize_wait_options(enqueue_options.delete(:dependency_wait))
      end

      def normalize_dependency_failure_policy(policy, configured)
        return unless configured

        DependencyOptions.normalize_failure_policy(policy)
      end

      def validate_dependency_set_options!(dependency_options)
        dependencies_configured = dependency_options[:dependencies_configured]
        validate_dependency_requirement!(
          dependency_options[:failure_policy_configured],
          dependencies_configured,
          "on_dependency_failure requires depends_on"
        )
        validate_dependency_requirement!(
          dependency_options[:dependency_wait_configured],
          dependencies_configured,
          "dependency_wait requires depends_on"
        )
      end

      def validate_dependency_requirement!(configured, dependencies_configured, message)
        return if !configured || dependencies_configured

        raise ArgumentError, message
      end

      def apply_dependency_set_options(dependency_options)
        if dependency_options[:dependencies_configured]
          @temporal_dependencies = dependency_options[:dependencies]
          @temporal_dependency_failure_policy = dependency_options[:failure_policy] || :fail
        end
        return unless dependency_options[:dependency_wait_configured]

        @temporal_dependency_wait = dependency_options[:dependency_wait]
      end
    end
  end
end

ActiveJob::Base.prepend(ActiveJob::Temporal::DependencyOptions) if defined?(ActiveJob::Base)
