# frozen_string_literal: true

require "time"
require "temporalio/worker/interceptor"

module ActiveJob
  module Temporal
    class WorkerHealth
      include Temporalio::Worker::Interceptor::Activity

      def initialize(task_queue:, namespace:, target:, max_concurrent_activities:, max_concurrent_workflows:)
        @task_queue = task_queue
        @namespace = namespace
        @target = target
        @max_concurrent_activities = max_concurrent_activities
        @max_concurrent_workflows = max_concurrent_workflows
        @mutex = Mutex.new
        @started_at = nil
        @worker_running = false
        @active_tasks = 0
        @last_poll = nil
      end

      def mark_started!
        @mutex.synchronize do
          @started_at ||= Time.now
          @worker_running = true
        end
        Metrics.record_worker_started
      end

      def mark_stopped!
        @mutex.synchronize do
          @worker_running = false
        end
        Metrics.record_worker_stopped
      end

      def record_task_started!(now: Time.now)
        active_tasks = @mutex.synchronize do
          @active_tasks += 1
          @last_poll = now
          @active_tasks
        end
        Metrics.record_active_tasks(active_tasks)
      end

      def record_task_finished!
        active_tasks = @mutex.synchronize do
          @active_tasks = [@active_tasks - 1, 0].max
          @active_tasks
        end
        Metrics.record_active_tasks(active_tasks)
      end

      def snapshot(now: Time.now)
        @mutex.synchronize do
          {
            status: @worker_running ? "ok" : "stopped",
            worker_running: @worker_running,
            started_at: iso8601(@started_at),
            last_poll: iso8601(@last_poll),
            active_tasks: @active_tasks,
            uptime_seconds: uptime_seconds(now),
            task_queue: @task_queue,
            namespace: @namespace,
            target: @target,
            max_concurrent_activities: @max_concurrent_activities,
            max_concurrent_workflows: @max_concurrent_workflows,
            pid: Process.pid
          }
        end
      end

      def intercept_activity(next_interceptor)
        ActivityInbound.new(self, next_interceptor)
      end

      private

      def iso8601(time)
        time&.utc&.iso8601
      end

      def uptime_seconds(now)
        return 0 unless @started_at

        [now - @started_at, 0].max.round
      end

      class ActivityInbound < Temporalio::Worker::Interceptor::Activity::Inbound
        def initialize(worker_health, next_interceptor)
          super(next_interceptor)
          @worker_health = worker_health
        end

        def execute(input)
          @worker_health.record_task_started!
          super
        ensure
          @worker_health.record_task_finished!
        end
      end
    end
  end
end
