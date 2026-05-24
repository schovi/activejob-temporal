# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::WorkerHealth do
  subject(:worker_health) do
    described_class.new(
      task_queue: "critical",
      namespace: "production",
      target: "temporal.example.com:7233",
      max_concurrent_activities: 50,
      max_concurrent_workflows: 10
    )
  end

  before do
    allow(ActiveJob::Temporal::Observability).to receive(:emit)
  end

  it "reports stopped state before the worker starts" do
    payload = worker_health.snapshot

    expect(payload[:status]).to eq("stopped")
    expect(payload[:worker_running]).to be(false)
    expect(payload[:uptime_seconds]).to eq(0)
    expect(payload[:active_tasks]).to eq(0)
    expect(payload[:last_poll]).to be_nil
    expect(payload[:task_queue]).to eq("critical")
    expect(payload[:namespace]).to eq("production")
    expect(payload[:target]).to eq("temporal.example.com:7233")
    expect(payload[:max_concurrent_activities]).to eq(50)
    expect(payload[:max_concurrent_workflows]).to eq(10)
    expect(payload[:pid]).to eq(Process.pid)
  end

  it "reports ok state while the worker is running" do
    started_at = Time.utc(2026, 5, 20, 10, 0, 0)
    allow(Time).to receive(:now).and_return(started_at)
    worker_health.mark_started!

    payload = worker_health.snapshot(now: started_at + 12)

    expect(payload[:status]).to eq("ok")
    expect(payload[:worker_running]).to be(true)
    expect(payload[:started_at]).to eq("2026-05-20T10:00:00Z")
    expect(payload[:uptime_seconds]).to eq(12)
    expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
      :worker_start,
      hash_including(task_queue: "critical", namespace: "production")
    )
  end

  it "tracks active activity tasks and last task start" do
    polled_at = Time.utc(2026, 5, 20, 10, 1, 0)

    worker_health.record_task_started!(now: polled_at)
    started_payload = worker_health.snapshot

    expect(started_payload[:active_tasks]).to eq(1)
    expect(started_payload[:last_poll]).to eq("2026-05-20T10:01:00Z")

    worker_health.record_task_finished!

    expect(worker_health.snapshot[:active_tasks]).to eq(0)
    expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
      :active_tasks,
      hash_including(task_queue: "critical", count: 1)
    )
    expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
      :active_tasks,
      hash_including(task_queue: "critical", count: 0)
    )
  end

  it "reports stopped after shutdown" do
    worker_health.mark_started!
    worker_health.mark_stopped!

    expect(worker_health.snapshot[:status]).to eq("stopped")
    expect(worker_health.snapshot[:worker_running]).to be(false)
    expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
      :worker_stop,
      hash_including(task_queue: "critical", namespace: "production")
    )
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

    expect(result).to eq(:ok)
    expect(active_tasks_during_execution).to eq(1)
    expect(worker_health.snapshot[:active_tasks]).to eq(0)
    expect(worker_health.snapshot[:last_poll]).not_to be_nil
  end
end
