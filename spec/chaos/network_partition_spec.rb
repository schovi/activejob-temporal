# frozen_string_literal: true

require "spec_helper"
require "active_support/core_ext/numeric/time"
require_relative "../support/chaos_helpers"

RSpec.describe "ActiveJob Temporal network partition recovery", :chaos do
  include ChaosHelpers

  around do |example|
    remember_original_adapter!
    setup_chaos_example!
    ensure_temporal_proxy!
    example.run
  ensure
    update_temporal_proxy_enabled(true)
    teardown_chaos_example!
  end

  it "runs queued work after the worker connection to Temporal is restored" do
    task_queue = "chaos-worker-partition-#{SecureRandom.hex(4)}"
    label = "worker-partition"
    @worker_pid = start_ready_worker_process(task_queue, target: ChaosHelpers::PROXIED_TEMPORAL_TARGET)

    with_network_partition do
      job = ChaosRecordingJob.set(queue: task_queue).perform_later(label)
      workflow_id = record_workflow_id(job)

      sleep 1.0
      expect(ChaosEventLog.events_for("job.completed", label: label)).to be_empty
      wait_for_workflow_status(workflow_id, Temporalio::Client::WorkflowExecutionStatus::RUNNING)
    end

    description = wait_for_terminal_status(@workflow_ids.last)

    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
    expect_completed_once(label)
  end

  it "runs retried enqueue work once after the client connection to Temporal is restored" do
    task_queue = "chaos-client-partition-#{SecureRandom.hex(4)}"
    label = "client-partition"
    @worker_pid = start_ready_worker_process(task_queue, target: ChaosHelpers::PROXIED_TEMPORAL_TARGET)
    job = ChaosRecordingJob.new(label)
    job.queue_name = task_queue
    workflow_id = record_workflow_id(job)

    with_temporal_target(ChaosHelpers::PROXIED_TEMPORAL_TARGET) do
      ActiveJob::Base.queue_adapter.enqueue(job)

      with_network_partition do
        expect do
          reset_temporal_queue_adapter!
        end.to raise_error(ActiveJob::Temporal::Error)
      end

      reset_temporal_queue_adapter!
      expect(ActiveJob::Base.queue_adapter.enqueue(job)).to be_nil
      description = wait_for_terminal_status(workflow_id)

      expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
    end

    expect_completed_once(label)
  end

  it "preserves scheduled work while the worker is partitioned past the timer due time" do
    task_queue = "chaos-scheduled-partition-#{SecureRandom.hex(4)}"
    label = "scheduled-partition"
    @worker_pid = start_ready_worker_process(task_queue, target: ChaosHelpers::PROXIED_TEMPORAL_TARGET)

    job = ChaosScheduledJob.set(queue: task_queue, wait: 8.seconds).perform_later(label)
    workflow_id = record_workflow_id(job)
    wait_for_history_event(workflow_id, :EVENT_TYPE_TIMER_STARTED)
    expect(ChaosEventLog.events_for("job.completed", label: label)).to be_empty

    with_network_partition do
      sleep 8.5
      expect(ChaosEventLog.events_for("job.completed", label: label)).to be_empty
    end

    description = wait_for_terminal_status(workflow_id)

    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
    expect_completed_once(label)
  end
end
