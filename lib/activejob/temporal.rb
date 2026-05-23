# frozen_string_literal: true

require "logger"
require "active_support/core_ext/numeric/time"

require_relative "temporal/version"
require_relative "temporal/configuration"
require_relative "temporal/configurable"
require_relative "temporal/client"
require_relative "temporal/logger"
require_relative "temporal/bind_policy"
require_relative "temporal/rails_environment_loader"
require_relative "temporal/certificate_watcher"
require_relative "temporal/reload_signal_queue"
require_relative "temporal/worker_client_reloader"
require_relative "temporal/worker_pool"
require_relative "temporal/audit_log"
require_relative "temporal/metrics"
require_relative "temporal/metrics_server"
require_relative "temporal/worker_health"
require_relative "temporal/health_check_server"
require_relative "temporal/middleware"
require_relative "temporal/payload_serializers"
require_relative "temporal/rate_limit_options"
require_relative "temporal/rate_limiters/memory"
require_relative "temporal/payload_encryption"
require_relative "temporal/payload"
require_relative "temporal/search_attributes"
require_relative "temporal/retry_mapper"
require_relative "temporal/signal_query_options"
require_relative "temporal/chain_options"
require_relative "temporal/dependency_options"
require_relative "temporal/job_payload_builder"
require_relative "temporal/schedule_options"
require_relative "temporal/conditional_enqueue"
require_relative "temporal/job_tags"
require_relative "temporal/temporal_options"
require_relative "temporal/schedule"
require_relative "temporal/schedulable"
require_relative "temporal/workflow_id_builder"
require_relative "temporal/workflow_enqueuer"
require_relative "temporal/adapter"
require_relative "temporal/workflows/aj_workflow"
require_relative "temporal/workflows/dead_letter_workflow"
require_relative "temporal/activities/rate_limit_activity"
require_relative "temporal/activities/dependency_status_activity"
require_relative "temporal/activities/aj_runner_activity"
require_relative "temporal/cancel"
require_relative "temporal/inspect"
require_relative "temporal/signal_query"
require_relative "temporal/dead_letter_queue"

module ActiveJob
  # ActiveJob adapter for Temporal workflow orchestration.
  #
  # This gem provides a durable, fault-tolerant execution backend for Rails ActiveJob
  # by leveraging Temporal's workflow engine. Jobs are executed as Temporal workflows
  # with automatic retries, scheduling, and observability.
  #
  # @example Basic configuration
  #   ActiveJob::Temporal.configure do |config|
  #     config.target = "temporal.example.com:7233"
  #     config.namespace = "production"
  #     config.task_queue_prefix = "my-app"
  #   end
  #
  # @example Using the adapter in a job
  #   class MyJob < ApplicationJob
  #     self.queue_adapter = :temporal
  #
  #     def perform(arg1, arg2)
  #       # Job logic here
  #     end
  #   end
  #
  # @example Complete configuration with error handling
  #   begin
  #     ActiveJob::Temporal.configure do |config|
  #       config.target = "temporal.example.com:7233"
  #       config.namespace = "production"
  #       config.default_activity_timeout = 10.minutes
  #       config.max_payload_size_kb = 250
  #     end
  #     ActiveJob::Temporal.config.validate!
  #   rescue ActiveJob::Temporal::ConfigurationError => e
  #     Rails.logger.error("Temporal configuration invalid: #{e.message}")
  #     raise
  #   end
  #
  # @see https://github.com/temporalio/sdk-ruby Temporal Ruby SDK
  module Temporal
    # Raised when attempting to cancel a job that does not exist.
    #
    # @see Cancel.cancel
    class WorkflowNotFoundError < Error; end

    # Raised when Temporal cluster is unreachable.
    #
    # @see Client.build
    # @see Cancel.cancel
    class TemporalConnectionError < Error; end

    extend Configurable

    class << self
      # Returns the memoized Temporal client connection for the process.
      #
      # The client is connected to the Temporal server specified in the configuration.
      # TLS options can be provided via configuration attributes or environment variables:
      # - TEMPORAL_TLS_CERT: TLS certificate
      # - TEMPORAL_TLS_KEY: TLS private key
      # - TEMPORAL_TLS_SERVER_NAME: TLS server name
      #
      # @return [Temporalio::Client] the connected Temporal client
      # @raise [ActiveJob::Temporal::Error] if connection fails due to network or authentication issues
      # @raise [ActiveJob::Temporal::TemporalConnectionError] if Temporal cluster is unreachable
      # @raise [Errno::ECONNREFUSED] if Temporal cluster is not accepting connections
      # @raise [SocketError] if Temporal hostname cannot be resolved
      # @raise [OpenSSL::SSL::SSLError] if TLS configuration is invalid
      # @example Get the client
      #   client = ActiveJob::Temporal.client
      #   client.list_workflows("ajQueue='default'")
      #
      # @example Using client for workflow queries
      #   client = ActiveJob::Temporal.client
      #   workflows = client.list_workflows("ajClass='MyJob'")
      #   workflows.each { |wf| puts wf.id }
      #
      # @example Accessing workflow handles
      #   client = ActiveJob::Temporal.client
      #   handle = client.workflow_handle("ajwf:MyJob:abc-123")
      #   result = handle.result
      #
      # @see Client.build
      def client
        client_mutex.synchronize do
          @client ||= Client.build(config)
        end
      end

      def reload_client!
        fresh_client = Client.build(config)
        begin
          yield fresh_client if block_given?
        rescue StandardError
          close_client(fresh_client)
          raise
        end

        previous_client = nil

        client_mutex.synchronize do
          previous_client = @client
          @client = fresh_client
        end

        close_client(previous_client) unless previous_client.equal?(fresh_client)
        fresh_client
      end

      # Cancels a running or scheduled job by job ID.
      #
      # This method requests cancellation for the Temporal workflow associated with the job.
      # Cancellation is asynchronous and best-effort: the job will stop only if it is actively
      # heartbeating. See Cancel module documentation for details.
      #
      # @param job_class [Class] the ActiveJob class (used to determine task queue)
      # @param job_id [String] the unique job identifier
      # @return [Boolean, nil] false if workflow already completed, nil if cancellation requested
      # @raise [ActiveJob::Temporal::WorkflowNotFoundError] if job never existed or already removed from history
      # @raise [ActiveJob::Temporal::TemporalConnectionError] if Temporal cluster is unreachable
      # @example Cancel a scheduled job
      #   ActiveJob::Temporal.cancel(MyJob, "job-123-abc")
      # @example Handle cancellation outcomes
      #   result = ActiveJob::Temporal.cancel(MyJob, "abc-123")
      #   case result
      #   when false
      #     puts "Job already completed"
      #   when nil
      #     puts "Cancellation requested"
      #   end
      #
      # @example Cancel with error handling
      #   begin
      #     ActiveJob::Temporal.cancel(MyJob, "unknown-id")
      #   rescue ActiveJob::Temporal::WorkflowNotFoundError
      #     puts "Job does not exist"
      #   end
      #
      # @note Cancellation Requires Heartbeating
      #   For jobs to respond to cancellation, they must check for cancellation by heartbeating
      #   or polling Temporalio::Activity::Context.current.cancelled?. Without heartbeating,
      #   long-running activities will complete before they detect the cancellation signal.
      #
      # @see Cancel.cancel
      def cancel(job_class, job_id)
        Cancel.cancel(job_class, job_id)
      end

      def cancel_all(job_class)
        Cancel.cancel_all(job_class)
      end

      def cancel_where(filters)
        Cancel.cancel_where(filters)
      end

      def status(job_class, job_id)
        Inspect.status(job_class, job_id)
      end

      def signal(job_class, job_id, signal_name, *)
        SignalQuery.signal(job_class, job_id, signal_name, *)
      end

      def query(job_class, job_id, query_name, *, reject_condition: SignalQuery::DEFAULT_REJECT_CONDITION)
        SignalQuery.query(job_class, job_id, query_name, *, reject_condition: reject_condition)
      end

      def running?(job_class, job_id)
        Inspect.running?(job_class, job_id)
      end

      def completed?(job_class, job_id)
        Inspect.completed?(job_class, job_id)
      end

      def failed?(job_class, job_id)
        Inspect.failed?(job_class, job_id)
      end

      def dead_letter_entry(job_class, job_id)
        DeadLetterQueue.entry(job_class, job_id)
      end

      def dead_letter_entries(queue: nil, limit: DeadLetterQueue::DEFAULT_ENTRIES_LIMIT)
        DeadLetterQueue.entries(queue: queue, limit: limit)
      end

      def retry_dead_letter(job_class, job_id, queue: nil)
        DeadLetterQueue.retry(job_class, job_id, queue: queue)
      end

      def discard_dead_letter(job_class, job_id, reason: nil)
        DeadLetterQueue.discard(job_class, job_id, reason: reason)
      end

      private

      def client_mutex
        @client_mutex ||= Mutex.new
      end

      def close_client(client)
        return unless client.respond_to?(:close)

        client.close
      rescue StandardError
        nil
      end
    end
  end
end
