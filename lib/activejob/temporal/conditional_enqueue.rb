# frozen_string_literal: true

require "active_job"
require "active_support/concern"
require_relative "configured_job_compatibility"

module ActiveJob
  module Temporal
    # Adds conditional enqueue helpers to ActiveJob classes.
    module ConditionalEnqueue
      extend ActiveSupport::Concern

      def self.job_arguments(arguments, keyword_arguments)
        return arguments if keyword_arguments.empty?

        arguments + [keyword_arguments]
      end

      def self.condition_allows_enqueue?(receiver, condition, arguments)
        !!evaluate_condition(receiver, condition, arguments)
      end

      def self.evaluate_condition(receiver, condition, arguments)
        return receiver.public_send(condition, arguments) if condition.is_a?(Symbol) || condition.is_a?(String)
        return condition.call(arguments) if condition.respond_to?(:call)

        raise ArgumentError, "condition must be a Symbol, String, or respond to #call"
      end

      class_methods do
        def perform_later_if(condition, *arguments, **keyword_arguments, &)
          condition_arguments = ConditionalEnqueue.job_arguments(arguments, keyword_arguments)
          return nil unless ConditionalEnqueue.condition_allows_enqueue?(self, condition, condition_arguments)

          perform_later(*arguments, **keyword_arguments, &)
        end
      end
    end

    # Adds conditional enqueue helpers to ActiveJob configured jobs.
    module ConfiguredConditionalEnqueue
      def perform_later_if(condition, *arguments, **keyword_arguments, &)
        job_class = ConfiguredJobCompatibility.job_class(self, feature: "conditional_enqueue")
        condition_arguments = ConditionalEnqueue.job_arguments(arguments, keyword_arguments)
        return nil unless ConditionalEnqueue.condition_allows_enqueue?(job_class, condition, condition_arguments)

        perform_later(*arguments, **keyword_arguments, &)
      end
    end
  end
end

ActiveJob::Base.include(ActiveJob::Temporal::ConditionalEnqueue) if defined?(ActiveJob::Base)

if defined?(ActiveJob::ConfiguredJob)
  ActiveJob::ConfiguredJob.include(ActiveJob::Temporal::ConfiguredConditionalEnqueue)
end
