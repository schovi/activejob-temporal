# frozen_string_literal: true

require "temporalio/error"
require_relative "workflow_id_builder"

module ActiveJob
  module Temporal
    # @api private
    module StandaloneActivity
      STATES = {
        RUNNING: :running,
        PAUSED: :running,
        COMPLETED: :completed,
        FAILED: :failed,
        CANCELED: :canceled,
        TERMINATED: :terminated,
        TIMED_OUT: :timed_out
      }.freeze

      module_function

      def enabled?(job_class)
        job_class.respond_to?(:temporal_standalone_activity?) && job_class.temporal_standalone_activity?
      end

      def with_handle(client, job_class, job_id)
        return unless client.respond_to?(:activity_handle)

        activity_id = WorkflowIdBuilder.default_from_job_class(job_class, job_id)
        yield client.activity_handle(activity_id)
      rescue Temporalio::Error::RPCError => e
        return if e.code == Temporalio::Error::RPCError::Code::NOT_FOUND
        return if e.code == Temporalio::Error::RPCError::Code::UNIMPLEMENTED && !enabled?(job_class)

        raise
      end

      def status(client, job_class, job_id)
        with_handle(client, job_class, job_id) do |handle|
          activity_status(describe_activity(handle))
        end
      end

      def describe_activity(handle)
        if handle.method(:describe).parameters.include?(%i[key include_last_failure])
          handle.describe(include_last_failure: true)
        else
          handle.describe
        end
      end

      def activity_status(description)
        {
          state: state(description.status),
          workflow_id: description.activity_id,
          run_id: description.activity_run_id,
          started_at: description.last_started_time,
          closed_at: description.close_time,
          attempt: description.attempt,
          last_failure: failure_message(description.last_failure)
        }
      end

      def failure_message(failure)
        return unless failure

        type = failure.type if failure.respond_to?(:type)
        [type, failure.message].compact.reject(&:empty?).join(": ").presence
      end

      private_class_method :describe_activity, :activity_status, :failure_message

      def state(status)
        return :unknown unless defined?(Temporalio::Client::ActivityExecutionStatus)

        statuses = Temporalio::Client::ActivityExecutionStatus
        STATES.each do |name, state|
          return state if statuses.const_defined?(name, false) && statuses.const_get(name, false) == status
        end
        :unknown
      end
    end
  end
end
