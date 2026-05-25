# frozen_string_literal: true

require "active_support/duration"

module ActiveJob
  module Temporal
    class ExternalOperation
      ACTIVITY = "activity"
      WORKFLOW = "workflow"

      attr_reader :operation, :temporal_type, :options

      def self.activity(temporal_type, **options)
        new(ACTIVITY, temporal_type, options)
      end

      def self.workflow(temporal_type, **options)
        new(WORKFLOW, temporal_type, options)
      end

      def self.normalize(value)
        return value.to_h if value.is_a?(self)
        return normalize_hash(value) if external_operation_hash?(value)

        nil
      end

      def self.external_operation_hash?(value)
        value.respond_to?(:[]) &&
          !payload_value(value, :temporal_operation).nil? &&
          !payload_value(value, :temporal_type).nil?
      end

      def initialize(operation, temporal_type, options)
        @operation = normalize_operation(operation)
        @temporal_type = normalize_temporal_type(temporal_type)
        @options = ExternalOperationOptions.normalize(@operation, options)
      end

      def to_h
        {
          temporal_operation: operation,
          temporal_type: temporal_type,
          options: options.dup
        }
      end

      class << self
        def normalize_hash(value)
          operation = payload_value(value, :temporal_operation)
          temporal_type = payload_value(value, :temporal_type)
          options = payload_value(value, :options) || {}

          new(operation, temporal_type, options).to_h
        end

        def payload_value(payload, key)
          payload[key] || payload[key.to_s]
        end
      end

      private

      def normalize_operation(operation)
        case operation.to_s
        when ACTIVITY then ACTIVITY
        when WORKFLOW then WORKFLOW
        else raise ArgumentError, "external Temporal operation must be activity or workflow"
        end
      end

      def normalize_temporal_type(value)
        unless value.is_a?(String) && !value.strip.empty?
          raise ArgumentError, "external Temporal type name must be a non-empty String"
        end

        value
      end
    end

    class ExternalOperationOptions
      ACTIVITY_OPTION_KEYS = %i[
        activity_id
        heartbeat_timeout
        retry_policy
        schedule_to_close_timeout
        schedule_to_start_timeout
        start_to_close_timeout
        summary
        task_queue
      ].freeze

      WORKFLOW_OPTION_KEYS = %i[
        cron_schedule
        execution_timeout
        id
        memo
        retry_policy
        run_timeout
        static_details
        static_summary
        task_queue
        task_timeout
      ].freeze

      DURATION_OPTION_KEYS = %i[
        execution_timeout
        heartbeat_timeout
        run_timeout
        schedule_to_close_timeout
        schedule_to_start_timeout
        start_to_close_timeout
        task_timeout
      ].freeze

      RETRY_POLICY_DURATION_KEYS = %i[initial_interval max_interval].freeze

      def self.normalize(operation, options)
        supported_keys = option_keys_for(operation)
        normalized_options = options.each_with_object({}) do |(key, value), normalized|
          normalized_key = key.to_sym
          unless supported_keys.include?(normalized_key)
            raise ArgumentError, external_options_error(operation, supported_keys)
          end

          normalized[normalized_key] = normalize_option_value(normalized_key, value)
        end
        normalize_task_queue!(normalized_options)
        normalized_options
      end

      class << self
        private

        def option_keys_for(operation)
          case operation.to_s
          when ExternalOperation::ACTIVITY then ACTIVITY_OPTION_KEYS
          when ExternalOperation::WORKFLOW then WORKFLOW_OPTION_KEYS
          else raise ArgumentError, "external Temporal operation must be activity or workflow"
          end
        end

        def external_options_error(operation, supported_keys)
          "external Temporal #{operation} options only support #{supported_keys.join(', ')}"
        end

        def normalize_option_value(key, value)
          return normalize_duration(value) if DURATION_OPTION_KEYS.include?(key)
          return normalize_retry_policy(value) if key == :retry_policy
          return normalize_task_queue(value) if key == :task_queue

          value
        end

        def normalize_retry_policy(value)
          value = value.to_h if value.respond_to?(:to_h) && !value.is_a?(Hash)
          return value unless value.is_a?(Hash)

          value.each_with_object({}) do |(key, retry_value), normalized|
            normalized_key = key.to_sym
            normalized[normalized_key] = retry_policy_value(normalized_key, retry_value)
          end
        end

        def retry_policy_value(key, value)
          return normalize_duration(value) if RETRY_POLICY_DURATION_KEYS.include?(key)

          value
        end

        def normalize_duration(value)
          case value
          when ActiveSupport::Duration, Numeric
            value.to_f
          else
            raise ArgumentError, "Temporal timeout values must be numeric or ActiveSupport::Duration"
          end
        end

        def normalize_task_queue!(options)
          options[:task_queue] = normalize_task_queue(options[:task_queue])
        end

        def normalize_task_queue(value)
          task_queue = value.to_s
          return task_queue unless task_queue.strip.empty?

          raise ArgumentError, "external Temporal steps require task_queue"
        end
      end
    end
  end
end
