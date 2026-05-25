# frozen_string_literal: true

require "active_job"

module ActiveJob
  module Temporal
    class JobDescriptor
      attr_reader :job_class, :options

      def self.normalize(value)
        return value.to_h if value.is_a?(self)

        nil
      end

      def initialize(job_class, options = {})
        @job_class = normalize_job_class(job_class)
        @options = options.dup
      end

      def to_h
        {
          job_class: job_class.name,
          options: options.dup
        }
      end

      private

      def normalize_job_class(job_class)
        return job_class if job_class.is_a?(Class) && job_class < ActiveJob::Base && job_class.name

        raise ArgumentError, "Temporal job descriptors require a named ActiveJob class"
      end
    end
  end
end
