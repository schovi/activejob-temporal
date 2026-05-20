# frozen_string_literal: true

require "temporalio/client/schedule"

module ActiveJob
  module Temporal
    class ScheduleOptions
      OVERLAP_POLICIES = {
        skip: Temporalio::Client::Schedule::OverlapPolicy::SKIP,
        buffer: Temporalio::Client::Schedule::OverlapPolicy::BUFFER_ONE,
        buffer_one: Temporalio::Client::Schedule::OverlapPolicy::BUFFER_ONE,
        buffer_all: Temporalio::Client::Schedule::OverlapPolicy::BUFFER_ALL,
        allow_all: Temporalio::Client::Schedule::OverlapPolicy::ALLOW_ALL,
        cancel_other: Temporalio::Client::Schedule::OverlapPolicy::CANCEL_OTHER,
        terminate_other: Temporalio::Client::Schedule::OverlapPolicy::TERMINATE_OTHER
      }.freeze

      attr_reader :job_class, :id, :cron_expressions, :timezone, :overlap_policy, :args, :queue,
                  :paused, :trigger_immediately

      def initialize(job_class, options)
        options = options.transform_keys(&:to_sym)

        @job_class = job_class
        @id = normalize_id(options.fetch(:id, default_id))
        @cron_expressions = normalize_cron(options.fetch(:cron))
        @timezone = normalize_timezone(options.fetch(:timezone, "UTC"))
        @overlap_policy = normalize_overlap_policy(options.fetch(:overlap_policy, :skip))
        @args = normalize_args(options.fetch(:args, []))
        @queue = options[:queue]&.to_s
        @paused = options.fetch(:paused, false)
        @trigger_immediately = options.fetch(:trigger_immediately, false)
      end

      def cron
        return cron_expressions.first if cron_expressions.one?

        cron_expressions
      end

      def temporal_overlap_policy
        OVERLAP_POLICIES.fetch(overlap_policy)
      end

      def to_h
        {
          id: id,
          cron: cron,
          timezone: timezone,
          overlap_policy: overlap_policy,
          args: args,
          queue: queue,
          paused: paused,
          trigger_immediately: trigger_immediately
        }
      end

      private

      def default_id
        "ajsch:#{job_class.name}"
      end

      def normalize_id(value)
        value = value.to_s.strip
        raise ArgumentError, "schedule id must be present" if value.empty?

        value
      end

      def normalize_cron(value)
        expressions = value.is_a?(Array) ? value : [value]
        expressions.map do |expression|
          expression = expression.to_s.strip
          raise ArgumentError, "cron must be present" if expression.empty?

          expression
        end
      end

      def normalize_timezone(value)
        value = value.to_s.strip
        raise ArgumentError, "timezone must be present" if value.empty?

        value
      end

      def normalize_overlap_policy(value)
        policy = value.to_sym
        return policy if OVERLAP_POLICIES.key?(policy)

        raise ArgumentError,
              "Unsupported overlap_policy #{value.inspect}. " \
              "Supported policies are: #{OVERLAP_POLICIES.keys.join(', ')}"
      end

      def normalize_args(value)
        return [] if value.nil?
        return value if value.is_a?(Array)

        raise ArgumentError, "args must be an Array"
      end
    end
  end
end
