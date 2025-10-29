# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

RSpec.describe "ActiveJob Temporal retry behavior", :integration do
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal
    $attempt_count = 0
    $test_result = nil
    $discard_test_executed = false

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    stop_worker(@worker_thread)
    $attempt_count = 0
    $test_result = nil
    $discard_test_executed = false
  end

  def client
    TemporalTestHelper.client
  end

  it "retries transient errors according to retry_on configuration" do
    task_queue = "retry-test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    # Give worker a moment to start up
    sleep 0.5

    job = RetryTestJob.set(queue: task_queue).perform_later
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

    # Verify workflow history shows activity retry
    history = handle.fetch_history
    event_types = history.events.map(&:event_type)

    # Verify activity was scheduled and eventually completed
    expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_SCHEDULED)
    expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_COMPLETED)

    # Verify retry occurred by checking the attempt number in ACTIVITY_TASK_STARTED event
    # Note: Temporal Ruby SDK handles activity retries at the worker level,
    # so the workflow history shows only the final STARTED event, but its
    # attempt counter indicates how many times the activity was executed
    activity_started_event = history.events.find { |e| e.event_type == :EVENT_TYPE_ACTIVITY_TASK_STARTED }
    expect(activity_started_event).not_to be_nil
    expect(activity_started_event.activity_task_started_event_attributes.attempt).to eq(2)
  end

  it "discards non-retryable errors according to discard_on configuration" do
    task_queue = "discard-test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    # Give worker a moment to start up
    sleep 0.5

    job = DiscardTestJob.set(queue: task_queue).perform_later
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

    wait_for_workflow_failure(workflow_id)

    # Verify job executed exactly once (no retries)
    expect($discard_test_executed).to eq(true)

    # Verify workflow failed (not completed)
    handle = client.workflow_handle(workflow_id)
    description = handle.describe
    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::FAILED)

    # Verify workflow history shows activity failed with non-retryable error
    history = handle.fetch_history
    event_types = history.events.map(&:event_type)

    # Verify activity was scheduled and failed
    expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_SCHEDULED)
    expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_FAILED)
    expect(event_types).to include(:EVENT_TYPE_WORKFLOW_EXECUTION_FAILED)

    # Verify activity executed only once (no retries)
    activity_started_event = history.events.find { |e| e.event_type == :EVENT_TYPE_ACTIVITY_TASK_STARTED }
    expect(activity_started_event).not_to be_nil
    expect(activity_started_event.activity_task_started_event_attributes.attempt).to eq(1)
  end

  private

  def start_worker(task_queue)
    @worker = Temporalio::Worker.new(
      client: TemporalTestHelper.client,
      task_queue: task_queue,
      workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
      activities: [ActiveJob::Temporal::Activities::AjRunnerActivity]
    )

    Thread.new do
      @worker.run
    end
  end

  def stop_worker(thread)
    return unless thread&.alive?

    # Kill the worker thread
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

  def wait_for_workflow_failure(workflow_id)
    Timeout.timeout(5) do
      loop do
        handle = client.workflow_handle(workflow_id)
        description = handle.describe
        status = description.status
        # Break when workflow reaches a terminal state
        if [Temporalio::Client::WorkflowExecutionStatus::FAILED, Temporalio::Client::WorkflowExecutionStatus::COMPLETED].include?(status)
          break
        end

        sleep 0.1
      end
    end
  end
end
