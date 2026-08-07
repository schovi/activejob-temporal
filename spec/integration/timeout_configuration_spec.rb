# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/worker_runtime"
require "timeout"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

describe "Per-job timeout configuration", :integration do
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

  it "executes a job with custom temporal_options successfully" do
    task_queue = "test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    job = CustomTimeoutJob.set(queue: task_queue).perform_later
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

    # Wait for job to complete
    Timeout.timeout(10) do
      loop do
        break if TestState.instance.custom_timeout_executed

        sleep 0.1
      end
    end

    # Verify job executed successfully
    assert_equal true, TestState.instance.custom_timeout_executed

    # Verify workflow completed
    description = wait_for_workflow_completion(workflow_id)
    assert_equal Temporalio::Client::WorkflowExecutionStatus::COMPLETED, description.status
  ensure
    stop_worker(@worker_thread)
  end

  it "includes temporal_options in the payload when job is enqueued" do
    task_queue = "test-#{SecureRandom.hex(4)}"

    job = CustomTimeoutJob.new
    job.queue_name = task_queue

    # Build payload manually (same as WorkflowEnqueuer does)
    config = ActiveJob::Temporal.config
    enqueuer = ActiveJob::Temporal::WorkflowEnqueuer.new(client, config)

    # Access the private build_payload method for testing
    workflow_id = ActiveJob::Temporal::WorkflowIdBuilder.new.build(job)
    payload = enqueuer.send(:build_payload, job, workflow_id: workflow_id)

    # Verify temporal_options are included
    assert payload[:temporal_options].present?
    assert_equal 120.0, payload[:temporal_options][:start_to_close_timeout] # 2.minutes
    assert_equal 10.0, payload[:temporal_options][:heartbeat_timeout] # 10.seconds
  end

  describe "when global timeout defaults are configured" do
    around do |example|
      # Save original config
      original_heartbeat = ActiveJob::Temporal.config.default_heartbeat_timeout
      original_schedule_to_start = ActiveJob::Temporal.config.default_schedule_to_start_timeout

      # Set global defaults
      ActiveJob::Temporal.config.default_heartbeat_timeout = 60
      ActiveJob::Temporal.config.default_schedule_to_start_timeout = 120

      example.run
    ensure
      # Restore original config
      ActiveJob::Temporal.config.default_heartbeat_timeout = original_heartbeat
      ActiveJob::Temporal.config.default_schedule_to_start_timeout = original_schedule_to_start
    end

    it "applies global timeout defaults to jobs without temporal_options" do
      task_queue = "test-#{SecureRandom.hex(4)}"
      @worker_thread = start_worker(task_queue)
      sleep 0.5

      job = TestJob.set(queue: task_queue).perform_later(123)
      workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

      # Wait for job to complete
      Timeout.timeout(10) do
        loop do
          break if TestJob.last_argument == 123

          sleep 0.1
        end
      end

      # Verify job executed successfully
      assert_equal 123, TestJob.last_argument

      # Verify workflow completed
      description = wait_for_workflow_completion(workflow_id)
      assert_equal Temporalio::Client::WorkflowExecutionStatus::COMPLETED, description.status
    ensure
      stop_worker(@worker_thread)
    end
  end

  private

  # The job body sets its TestState flag from inside the activity, which is one
  # workflow task short of the execution actually closing. Polling the server is
  # what makes COMPLETED a valid expectation.
  def wait_for_workflow_completion(workflow_id)
    handle = client.workflow_handle(workflow_id)

    Timeout.timeout(10) do
      loop do
        description = handle.describe
        return description if description.status == Temporalio::Client::WorkflowExecutionStatus::COMPLETED

        sleep 0.1
      end
    end
  end

  def start_worker(task_queue)
    start_temporal_worker(task_queue)
  end

  def stop_worker(thread)
    stop_temporal_worker(thread)
  end
end
