# frozen_string_literal: true

require "spec_helper"
require "active_support/core_ext/numeric/time"
require_relative "../support/chaos_helpers"

RSpec.describe "ActiveJob Temporal worker crash recovery", :chaos do
  include ChaosHelpers

  around do |example|
    remember_original_adapter!
    setup_chaos_example!
    example.run
  ensure
    teardown_chaos_example!
  end

  it "runs a scheduled job after the worker dies while the workflow timer is sleeping" do
    task_queue = "chaos-scheduled-crash-#{SecureRandom.hex(4)}"
    label = "scheduled-crash"
    @worker_pid = start_ready_worker_process(task_queue)

    job = ChaosScheduledJob.set(queue: task_queue, wait: 8.seconds).perform_later(label)
    workflow_id = record_workflow_id(job)
    wait_for_history_event(workflow_id, :EVENT_TYPE_TIMER_STARTED)

    expect(ChaosEventLog.events_for("job.completed", label: label)).to be_empty
    stop_worker_process(@worker_pid, signal: "KILL")
    @worker_pid = nil
    sleep 8.5

    @worker_pid = start_worker_process(task_queue)
    description = wait_for_terminal_status(workflow_id)

    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
    expect_completed_once(label)
  end

  it "retries a heartbeat activity after the worker process dies mid-execution" do
    task_queue = "chaos-activity-crash-#{SecureRandom.hex(4)}"
    label = "activity-crash"
    @worker_pid = start_ready_worker_process(task_queue)

    job = ChaosLongRunningJob.set(queue: task_queue).perform_later(label, 2.0)
    workflow_id = record_workflow_id(job)
    first_start = wait_for_chaos_event("activity.started", label: label)

    stop_worker_process(@worker_pid, signal: "KILL")
    @worker_pid = start_worker_process(task_queue)
    description = wait_for_terminal_status(workflow_id, timeout: 45)

    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
    expect(ChaosEventLog.events_for("activity.started", label: label).size).to be >= 2
    expect_completed_once(label)
    expect(ChaosEventLog.events_for("job.completed", label: label).first[:idempotency_key])
      .to eq(first_start[:idempotency_key])
  end
end
