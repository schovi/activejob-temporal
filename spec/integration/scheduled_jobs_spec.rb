# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/worker_runtime"
require "timeout"
require "temporalio/worker"
require "active_support/core_ext/numeric/time"
require_relative "../fixtures/sample_jobs"

describe "ActiveJob Temporal scheduled jobs", :integration do
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal
    TestJob.last_argument = nil

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    stop_worker(@worker_thread)
    TestJob.last_argument = nil
  end

  def client
    TemporalTestHelper.client
  end

  it "executes a scheduled job after the specified delay" do
    @worker_thread = start_worker

    job = TestJob.set(wait: 5.seconds).perform_later(42)
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

    # Wait for the job to complete
    wait_for_result(42)

    assert_equal 42, TestJob.last_argument

    # Wait for workflow to reach completed state
    handle = client.workflow_handle(workflow_id)
    Timeout.timeout(5) do
      loop do
        description = handle.describe
        break if description.status == Temporalio::Client::WorkflowExecutionStatus::COMPLETED

        sleep 0.1
      end
    end

    # Verify workflow completed successfully
    description = handle.describe
    assert_equal Temporalio::Client::WorkflowExecutionStatus::COMPLETED, description.status

    # The key test: verify that a Temporal timer was used for scheduling
    # This proves the workflow delayed execution rather than running immediately
    history = handle.fetch_history
    event_types = history.events.map(&:event_type)
    assert_includes event_types, :EVENT_TYPE_TIMER_STARTED
  ensure
    stop_worker(@worker_thread)
  end

  private

  def start_worker
    start_temporal_worker("default")
  end

  def stop_worker(thread)
    stop_temporal_worker(thread)
  end

  def wait_for_result(expected)
    Timeout.timeout(10) do
      loop do
        break if TestJob.last_argument == expected

        sleep 0.1
      end
    end
  end
end
