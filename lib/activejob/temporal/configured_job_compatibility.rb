# frozen_string_literal: true

require "active_job"
require_relative "logger"

module ActiveJob
  module Temporal
    module ConfiguredJobCompatibility
      SUPPORTED_ACTIVE_JOB_MAJOR_MINOR = [
        [7, 2],
        [8, 0],
        [8, 1]
      ].freeze
      FEATURE_REPLACEMENTS = {
        "chain" => "ActiveJob::Temporal.job",
        "child_workflows" => "ActiveJob::Temporal.job",
        "conditional_enqueue" => "JobClass.perform_later_if or an explicit condition before " \
                                 "JobClass.set(...).perform_later"
      }.freeze
      ExtractedConfiguredJob = Struct.new(:job_class, :options, keyword_init: true)

      module_function

      def payload(value, feature:, normalize_options:)
        configured_job = extract(value, feature: feature)
        return unless configured_job

        {
          job_class: configured_job.job_class.name,
          options: normalize_options.call(configured_job.options)
        }
      end

      def job_class(value, feature:)
        extract(value, feature: feature)&.job_class
      end

      def configured_job?(value)
        defined?(ActiveJob::ConfiguredJob) && value.is_a?(ActiveJob::ConfiguredJob)
      end

      def extract(value, feature:)
        return unless configured_job?(value)

        validate_active_job_version!(feature)

        job_class = configured_job_instance_variable(value, :@job_class, feature)
        options = configured_job_instance_variable(value, :@options, feature)

        validate_job_class!(job_class, feature)
        validate_options!(options, feature)

        log_private_api(feature)

        ExtractedConfiguredJob.new(job_class: job_class, options: options.dup)
      end
      private_class_method :extract

      def active_job_class?(job_class)
        job_class.is_a?(Class) && job_class < ActiveJob::Base && job_class.name
      end

      def validate_job_class!(job_class, feature)
        return if active_job_class?(job_class)

        raise ArgumentError, unsupported_internals_message(feature, "@job_class")
      end
      private_class_method :validate_job_class!

      def validate_options!(options, feature)
        return if options.is_a?(Hash)

        raise ArgumentError, unsupported_internals_message(feature, "@options")
      end
      private_class_method :validate_options!

      def configured_job_instance_variable(value, name, feature)
        return value.instance_variable_get(name) if value.instance_variable_defined?(name)

        raise ArgumentError, unsupported_internals_message(feature, name)
      end
      private_class_method :configured_job_instance_variable

      def validate_active_job_version!(feature)
        return if supported_active_job_version?

        raise ArgumentError,
              "ActiveJob::ConfiguredJob internals are not supported for #{feature} on ActiveJob " \
              "#{active_job_version}; use #{replacement_for(feature)} instead"
      end
      private_class_method :validate_active_job_version!

      def supported_active_job_version?
        SUPPORTED_ACTIVE_JOB_MAJOR_MINOR.include?(active_job_version.segments.first(2))
      end
      private_class_method :supported_active_job_version?

      def active_job_version
        return ActiveJob.gem_version if ActiveJob.respond_to?(:gem_version)

        Gem::Version.new(ActiveJob::VERSION::STRING)
      end

      def unsupported_internals_message(feature, name)
        "ActiveJob::ConfiguredJob internals changed for #{feature}: expected #{name}; " \
          "use #{replacement_for(feature)} instead"
      end
      private_class_method :unsupported_internals_message

      def log_private_api(feature)
        ActiveJob::Temporal::Logger.warn(
          "active_job_configured_job_private_api",
          feature: feature,
          replacement: replacement_for(feature)
        )
      rescue StandardError
        nil
      end

      def replacement_for(feature)
        FEATURE_REPLACEMENTS.fetch(feature.to_s, "ActiveJob::Temporal.job")
      end
      private_class_method :replacement_for
    end
  end
end
