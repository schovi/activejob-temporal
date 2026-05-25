# frozen_string_literal: true

require "active_job"
require_relative "configured_job_compatibility"
require_relative "external_operation"
require_relative "job_descriptor"

module ActiveJob
  module Temporal
    module ChainOptions
      SUPPORTED_CONFIGURED_OPTIONS = %i[priority queue].freeze

      attr_reader :temporal_chain

      def self.normalize(chain)
        return nil if chain.nil?

        raise ArgumentError, "chain must be an Array of ActiveJob classes or configured jobs" unless chain.is_a?(Array)
        raise ArgumentError, "chain must contain at least one ActiveJob class or configured job" if chain.empty?

        chain.map { |job_class| normalize_job_class(job_class) }
      end

      def self.normalize_job_class(job_class)
        ExternalOperation.normalize(job_class) ||
          job_descriptor_payload(job_class) ||
          active_job_class_payload(job_class) ||
          configured_job_payload(job_class, feature: "chain") ||
          raise(ArgumentError, "chain entries must be ActiveJob classes or configured jobs")
      end
      private_class_method :normalize_job_class

      def self.job_descriptor_payload(job_class)
        payload = JobDescriptor.normalize(job_class)
        return unless payload

        payload.merge(options: normalize_configured_options(payload.fetch(:options)))
      end
      private_class_method :job_descriptor_payload

      def self.active_job_class_payload(job_class)
        return unless job_class.is_a?(Class) && job_class < ActiveJob::Base && job_class.name

        { job_class: job_class.name, options: {} }
      end
      private_class_method :active_job_class_payload

      def self.configured_job_payload(job_class, feature:)
        ConfiguredJobCompatibility.payload(
          job_class,
          feature: feature,
          normalize_options: method(:normalize_configured_options)
        )
      end
      private_class_method :configured_job_payload

      def self.normalize_configured_options(options)
        unsupported_options = options.keys.reject do |key|
          SUPPORTED_CONFIGURED_OPTIONS.include?(key.to_sym)
        end
        unless unsupported_options.empty?
          raise ArgumentError, "chain configured jobs only support queue and priority options"
        end

        options.each_with_object({}) do |(key, value), normalized|
          normalized[key.to_sym] = value
        end
      end
      private_class_method :normalize_configured_options

      def set(options = {})
        enqueue_options = options.dup
        normalized_chain = ChainOptions.normalize(enqueue_options.delete(:chain)) if enqueue_options.key?(:chain)

        super(enqueue_options).tap do
          @temporal_chain = normalized_chain if options.key?(:chain)
        end
      end
    end
  end
end

ActiveJob::Base.prepend(ActiveJob::Temporal::ChainOptions) if defined?(ActiveJob::Base)
