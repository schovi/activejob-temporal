# frozen_string_literal: true

require "active_job"
require_relative "external_operation"
require_relative "job_tags"

module ActiveJob
  module Temporal
    module ChildWorkflowOptions
      SUPPORTED_CONFIGURED_OPTIONS = %i[priority queue tags].freeze

      attr_reader :temporal_child_workflows

      def self.normalize(child_workflows)
        return nil if child_workflows.nil?

        unless child_workflows.is_a?(Array)
          raise ArgumentError, "child_workflows must be an Array of ActiveJob classes or configured jobs"
        end
        if child_workflows.empty?
          raise ArgumentError, "child_workflows must contain at least one ActiveJob class or configured job"
        end

        child_workflows.map { |child_workflow| normalize_job_class(child_workflow) }
      end

      def self.normalize_job_class(child_workflow)
        external_operation = ExternalOperation.normalize(child_workflow)
        return normalize_external_operation(external_operation) if external_operation

        active_job_class_payload(child_workflow) ||
          configured_job_payload(child_workflow) ||
          raise(ArgumentError, "child_workflows entries must be ActiveJob classes or configured jobs")
      end
      private_class_method :normalize_job_class

      def self.normalize_external_operation(external_operation)
        return external_operation if external_operation[:temporal_operation] == ExternalOperation::WORKFLOW

        raise ArgumentError, "child_workflows entries must be ActiveJob classes or configured jobs; " \
                             "external refs must be workflows"
      end
      private_class_method :normalize_external_operation

      def self.active_job_class_payload(job_class)
        return unless job_class.is_a?(Class) && job_class < ActiveJob::Base && job_class.name

        { job_class: job_class.name, options: {} }
      end
      private_class_method :active_job_class_payload

      def self.configured_job_payload(child_workflow)
        return unless defined?(ActiveJob::ConfiguredJob) && child_workflow.is_a?(ActiveJob::ConfiguredJob)

        configured_job_class = child_workflow.instance_variable_get(:@job_class)
        options = normalize_configured_options(child_workflow.instance_variable_get(:@options) || {})
        active_job_class_payload(configured_job_class)&.merge(options: options)
      end
      private_class_method :configured_job_payload

      def self.normalize_configured_options(options)
        unsupported_options = options.keys.reject do |key|
          SUPPORTED_CONFIGURED_OPTIONS.include?(key.to_sym)
        end
        unless unsupported_options.empty?
          raise ArgumentError, "child_workflows configured jobs only support queue, priority, and tags options"
        end

        options.each_with_object({}) do |(key, value), normalized|
          normalized[key.to_sym] = key.to_sym == :tags ? JobTags.normalize(value) : value
        end
      end
      private_class_method :normalize_configured_options

      def set(options = {})
        enqueue_options = options.dup
        normalized_children = if enqueue_options.key?(:child_workflows)
                                ChildWorkflowOptions.normalize(enqueue_options.delete(:child_workflows))
                              end

        super(enqueue_options).tap do
          @temporal_child_workflows = normalized_children if options.key?(:child_workflows)
        end
      end
    end
  end
end

ActiveJob::Base.prepend(ActiveJob::Temporal::ChildWorkflowOptions) if defined?(ActiveJob::Base)
