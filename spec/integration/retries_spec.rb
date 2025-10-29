# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

RSpec.describe "ActiveJob Temporal retry behavior", :integration do
  let(:client) { TemporalTestHelper.client }

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal
    $attempt_count = 0
    $test_result = nil

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    stop_worker(@worker_thread)
    $attempt_count = 0
    $test_result = nil
  end

  it "retries transient errors according to retry_on configuration" do
    @worker_thread = start_worker

    job = RetryTestJob.perform_later
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

    wait_for_result("success")
    wait_for_workflow_completion(workflow_id)

    # Verify job executed exactly twice (failed once, then succeeded)
    # The global variables prove the retry mechanism worked
    expect($test_result).to eq("success")
    expect($attempt_count).to eq(2)

    # Verify workflow completed successfully
    handle = client.workflow_handle(workflow_id)
    description = handle.describe
    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)

    # Verify workflow history
    # Note: Temporal Ruby SDK handles activity retries at the worker level,
    # so intermediate failures may not appear as separate events in workflow history.
    # The critical validation is that the job executed twice and eventually succeeded.
    history = handle.fetch_history
    event_types = history.events.map(&:event_type)

    # Verify activity was scheduled and completed
    expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_SCHEDULED)
    expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_COMPLETED)
  ensure
    stop_worker(@worker_thread)
  end

  private

  def start_worker
    Thread.new do
      worker = Temporalio::Worker.new(
        client: TemporalTestHelper.client,
        task_queue: "default",
        workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
        activities: [ActiveJob::Temporal::Activities::AjRunnerActivity]
      )
      worker.run
    end
  end

  def stop_worker(thread)
    return unless thread&.alive?

    thread.kill
    thread.join(5)
  end

  def wait_for_result(expected)
    Timeout.timeout(10) do
      loop do
        break if $test_result == expected

        sleep 0.1
      end
    end
  end

  def wait_for_workflow_completion(workflow_id)
    Timeout.timeout(5) do
      loop do
        handle = client.workflow_handle(workflow_id)
        description = handle.describe
        break if description.status == Temporalio::Client::WorkflowExecutionStatus::COMPLETED

        sleep 0.1
      end
    end
  end
end
