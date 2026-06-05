# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/worker_runtime"
require "timeout"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

describe "ActiveJob Temporal retry behavior", :integration do
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal
    TestState.instance.reset!

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    stop_worker(@worker_thread)
    TestState.instance.reset!
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
    # The test state proves the retry mechanism worked
    assert_equal "success", TestState.instance.test_result
    assert_equal 2, TestState.instance.attempt_count

    # Verify workflow completed successfully
    handle = client.workflow_handle(workflow_id)
    description = handle.describe
    assert_equal Temporalio::Client::WorkflowExecutionStatus::COMPLETED, description.status

    # Verify workflow history shows activity retry
    history = handle.fetch_history
    event_types = history.events.map(&:event_type)

    # Verify activity was scheduled and eventually completed
    assert_includes event_types, :EVENT_TYPE_ACTIVITY_TASK_SCHEDULED
    assert_includes event_types, :EVENT_TYPE_ACTIVITY_TASK_COMPLETED

    # Verify retry occurred by checking the attempt number in ACTIVITY_TASK_STARTED event
    # Note: Temporal Ruby SDK handles activity retries at the worker level,
    # so the workflow history shows only the final STARTED event, but its
    # attempt counter indicates how many times the activity was executed
    activity_started_event = history.events.find { |e| e.event_type == :EVENT_TYPE_ACTIVITY_TASK_STARTED }
    refute_nil activity_started_event
    assert_equal 2, activity_started_event.activity_task_started_event_attributes.attempt
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
    assert_equal true, TestState.instance.discard_test_executed

    # Verify workflow failed (not completed)
    handle = client.workflow_handle(workflow_id)
    description = handle.describe
    assert_equal Temporalio::Client::WorkflowExecutionStatus::FAILED, description.status

    # Verify workflow history shows activity failed with non-retryable error
    history = handle.fetch_history
    event_types = history.events.map(&:event_type)

    # Verify activity was scheduled and failed
    assert_includes event_types, :EVENT_TYPE_ACTIVITY_TASK_SCHEDULED
    assert_includes event_types, :EVENT_TYPE_ACTIVITY_TASK_FAILED
    assert_includes event_types, :EVENT_TYPE_WORKFLOW_EXECUTION_FAILED

    # Verify activity executed only once (no retries)
    activity_started_event = history.events.find { |e| e.event_type == :EVENT_TYPE_ACTIVITY_TASK_STARTED }
    refute_nil activity_started_event
    assert_equal 1, activity_started_event.activity_task_started_event_attributes.attempt
  end

  private

  def start_worker(task_queue)
    start_temporal_worker(task_queue)
  end

  def stop_worker(thread)
    stop_temporal_worker(thread)
  end

  def wait_for_result(expected)
    Timeout.timeout(10) do
      loop do
        break if TestState.instance.test_result == expected

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
