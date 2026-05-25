# frozen_string_literal: true

require "active_job"
require_relative "logger"

module ActiveJob
  module Temporal
    module ConfiguredJobCompatibility
      module_function

      def payload(value, feature:, normalize_options:)
        return unless configured_job?(value)

        log_private_api(feature)

        job_class = value.instance_variable_get(:@job_class)
        return unless active_job_class?(job_class)

        {
          job_class: job_class.name,
          options: normalize_options.call(value.instance_variable_get(:@options) || {})
        }
      end

      def configured_job?(value)
        defined?(ActiveJob::ConfiguredJob) && value.is_a?(ActiveJob::ConfiguredJob)
      end

      def active_job_class?(job_class)
        job_class.is_a?(Class) && job_class < ActiveJob::Base && job_class.name
      end

      def log_private_api(feature)
        ActiveJob::Temporal::Logger.warn(
          "active_job_configured_job_private_api",
          feature: feature,
          replacement: "ActiveJob::Temporal.job"
        )
      rescue StandardError
        nil
      end
    end
  end
end
