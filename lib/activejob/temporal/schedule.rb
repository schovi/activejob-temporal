# frozen_string_literal: true

require "active_job"
require "temporalio/client/schedule"

require_relative "adapter"
require_relative "job_payload_builder"
require_relative "logger"
require_relative "schedule_options"
require_relative "search_attributes"
require_relative "workflows/aj_workflow"

module ActiveJob
  module Temporal
    class Schedule
      attr_reader :job_class

      def initialize(job_class, options = {})
        options = options.transform_keys(&:to_sym)
        client = options.delete(:client)
        config = options.delete(:config) || ActiveJob::Temporal.config
        payload_builder = options.delete(:payload_builder)

        @job_class = job_class
        @options = ScheduleOptions.new(job_class, options)
        @client = client
        @config = config
        @payload_builder = payload_builder || JobPayloadBuilder.new(config)
      end

      def id = @options.id

      def cron_expressions = @options.cron_expressions

      def timezone = @options.timezone

      def overlap_policy = @options.overlap_policy

      def args = @options.args

      def queue = @options.queue

      def paused = @options.paused

      def trigger_immediately = @options.trigger_immediately

      def cron
        @options.cron
      end

      def create
        temporal_schedule = to_temporal_schedule
        handle = client.create_schedule(
          id,
          temporal_schedule,
          trigger_immediately: trigger_immediately,
          memo: nil,
          search_attributes: nil
        )
        log_created(task_queue: temporal_schedule.action.task_queue, duplicate: false)
        handle
      rescue StandardError => e
        raise unless schedule_already_running?(e)

        handle_existing_schedule
      end

      def handle
        client.schedule_handle(id)
      end

      def options
        @options.to_h
      end

      def to_temporal_schedule
        Temporalio::Client::Schedule.new(
          action: schedule_action,
          spec: schedule_spec,
          policy: schedule_policy,
          state: schedule_state
        )
      end

      private

      def client
        @client || ActiveJob::Temporal.client
      end

      def schedule_action
        job = build_job

        Temporalio::Client::Schedule::Action::StartWorkflow.new(
          Workflows::AjWorkflow,
          @payload_builder.build(job),
          id: workflow_id_prefix,
          task_queue: Adapter.resolve_task_queue(job, config: @config),
          search_attributes: search_attributes_for(job)
        )
      end

      def schedule_spec
        Temporalio::Client::Schedule::Spec.new(
          cron_expressions: cron_expressions,
          time_zone_name: timezone
        )
      end

      def schedule_policy
        Temporalio::Client::Schedule::Policy.new(overlap: @options.temporal_overlap_policy)
      end

      def schedule_state
        Temporalio::Client::Schedule::State.new(
          paused: paused,
          note: "ActiveJob Temporal schedule for #{job_class.name}"
        )
      end

      def build_job
        job = job_class.new(*args)
        job.job_id = id if job.respond_to?(:job_id=)
        job.queue_name = queue if queue && job.respond_to?(:queue_name=)
        job
      end

      def search_attributes_for(job)
        return unless @config.respond_to?(:enable_search_attributes) && @config.enable_search_attributes

        SearchAttributes.for(job)
      end

      def workflow_id_prefix
        "ajschwf:#{id}"
      end

      def schedule_already_running?(error)
        defined?(Temporalio::Error::ScheduleAlreadyRunningError) &&
          error.is_a?(Temporalio::Error::ScheduleAlreadyRunningError)
      end

      def handle_existing_schedule
        existing_handle = handle
        log_created(task_queue: Adapter.resolve_task_queue(build_job, config: @config), duplicate: true)
        existing_handle
      end

      def log_created(task_queue:, duplicate:)
        Logger.log_event(
          "schedule_created",
          schedule_id: id,
          job_class: job_class.name,
          cron: cron,
          timezone: timezone,
          overlap_policy: overlap_policy,
          task_queue: task_queue,
          duplicate: duplicate
        )
      end
    end
  end
end
