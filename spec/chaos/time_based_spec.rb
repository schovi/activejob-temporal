# frozen_string_literal: true

require "spec_helper"
require "active_support/core_ext/numeric/time"
require_relative "../support/chaos_helpers"

RSpec.describe "ActiveJob Temporal time-based chaos behavior", :chaos do
  include ChaosHelpers

  around do |example|
    remember_original_adapter!
    setup_chaos_example!
    example.run
  ensure
    teardown_chaos_example!
  end

  it "uses a durable Temporal timer before executing scheduled work" do
    task_queue = "chaos-timer-#{SecureRandom.hex(4)}"
    label = "timer"
    @worker_pid = start_ready_worker_process(task_queue)

    job = ChaosScheduledJob.set(queue: task_queue, wait: 2.seconds).perform_later(label)
    workflow_id = record_workflow_id(job)

    timer_event = wait_for_history_event(workflow_id, :EVENT_TYPE_TIMER_STARTED)
    description = wait_for_terminal_status(workflow_id)

    expect(timer_event).not_to be_nil
    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
    expect_completed_once(label)
  end
end
