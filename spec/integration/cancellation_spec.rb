# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

RSpec.describe "ActiveJob Temporal cancellation", :integration do
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

  it "cancels a long-running job via heartbeat mechanism" do
    task_queue = "cancel-test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    # Give worker a moment to start up
    sleep 0.5

    job = LongRunningJob.set(queue: task_queue).perform_later
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

    # Wait for workflow to start executing
    wait_for_workflow_running(workflow_id)

    # Give the activity time to start executing and complete at least one iteration
    sleep 1.5

    # Cancel the job
    ActiveJob::Temporal.cancel(LongRunningJob, job.job_id)

    # Wait for workflow to be cancelled
    wait_for_workflow_cancellation(workflow_id)

    # Verify workflow status is CANCELED
    handle = client.workflow_handle(workflow_id)
    description = handle.describe
    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::CANCELED)

    # Verify job did not complete (heartbeat loop was interrupted)
    expect(TestState.instance.long_running_completed).to eq(false)
    # Verify job was interrupted mid-execution (not all 10 iterations)
    expect(TestState.instance.long_running_iterations).to be < 10
    # Verify job started executing (at least 1 iteration)
    expect(TestState.instance.long_running_iterations).to be > 0
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

  def wait_for_workflow_running(workflow_id)
    Timeout.timeout(5) do
      loop do
        handle = client.workflow_handle(workflow_id)
        description = handle.describe
        break if description.status == Temporalio::Client::WorkflowExecutionStatus::RUNNING

        sleep 0.1
      end
    end
  end

  def wait_for_workflow_cancellation(workflow_id)
    Timeout.timeout(5) do
      loop do
        handle = client.workflow_handle(workflow_id)
        description = handle.describe
        status = description.status
        # Break when workflow reaches CANCELED state
        break if status == Temporalio::Client::WorkflowExecutionStatus::CANCELED

        sleep 0.1
      end
    end
  end
end
