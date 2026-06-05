# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/worker_runtime"

describe ActiveJob::Temporal::WorkerHealth do
  let(:worker_health) do
    described_class.new(
      task_queue: "critical",
      namespace: "production",
      target: "temporal.example.com:7233",
      max_concurrent_activities: 50,
      max_concurrent_workflows: 10
    )
  end

  before do
    @observability_events = call_recorded_method(ActiveJob::Temporal::Observability, :emit)
  end

  it "reports stopped state before the worker starts" do
    payload = worker_health.snapshot

    assert_equal "stopped", payload[:status]
    refute payload[:worker_running]
    assert_equal 0, payload[:uptime_seconds]
    assert_equal 0, payload[:active_tasks]
    assert_nil payload[:last_poll]
    assert_equal "critical", payload[:task_queue]
    assert_equal "production", payload[:namespace]
    assert_equal "temporal.example.com:7233", payload[:target]
    assert_equal 50, payload[:max_concurrent_activities]
    assert_equal 10, payload[:max_concurrent_workflows]
    assert_equal Process.pid, payload[:pid]
  end

  it "reports ok state while the worker is running" do
    started_at = Time.utc(2026, 5, 20, 10, 0, 0)
    call_recorded_method(Time, :now, returns: started_at)
    worker_health.mark_started!

    payload = worker_health.snapshot(now: started_at + 12)

    assert_equal "ok", payload[:status]
    assert payload[:worker_running]
    assert_equal "2026-05-20T10:00:00Z", payload[:started_at]
    assert_equal 12, payload[:uptime_seconds]
    assert_observability_event :worker_start, task_queue: "critical", namespace: "production"
  end

  it "tracks active activity tasks and last task start" do
    polled_at = Time.utc(2026, 5, 20, 10, 1, 0)

    worker_health.record_task_started!(now: polled_at)
    started_payload = worker_health.snapshot

    assert_equal 1, started_payload[:active_tasks]
    assert_equal "2026-05-20T10:01:00Z", started_payload[:last_poll]

    worker_health.record_task_finished!

    assert_equal 0, worker_health.snapshot[:active_tasks]
    assert_observability_event :active_tasks, task_queue: "critical", count: 1
    assert_observability_event :active_tasks, task_queue: "critical", count: 0
  end

  it "reports stopped after shutdown" do
    worker_health.mark_started!
    worker_health.mark_stopped!

    assert_equal "stopped", worker_health.snapshot[:status]
    refute worker_health.snapshot[:worker_running]
    assert_observability_event :worker_stop, task_queue: "critical", namespace: "production"
  end

  it "wraps activity execution with health tracking" do
    health = worker_health
    active_tasks_during_execution = nil
    next_interceptor = Object.new
    next_interceptor.define_singleton_method(:execute) do |_input|
      active_tasks_during_execution = health.snapshot[:active_tasks]
      :ok
    end
    inbound = worker_health.intercept_activity(next_interceptor)

    result = inbound.execute(:input)

    assert_equal :ok, result
    assert_equal 1, active_tasks_during_execution
    assert_equal 0, worker_health.snapshot[:active_tasks]
    refute_nil worker_health.snapshot[:last_poll]
  end

  def assert_observability_event(event_name, **expected_attributes)
    event = @observability_events.calls_for(:emit).find do |call|
      payload = call.arguments[1] || call.keywords

      call.arguments.first == event_name &&
        expected_attributes.all? { |key, value| payload[key] == value }
    end

    refute_nil event
  end
end
