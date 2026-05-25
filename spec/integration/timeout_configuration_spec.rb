# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/worker_runtime"
require "timeout"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

RSpec.describe "Per-job timeout configuration", :integration do
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
    expect(TestState.instance.custom_timeout_executed).to be(true)

    # Verify workflow completed
    description = client.workflow_handle(workflow_id).describe
    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
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
    expect(payload[:temporal_options]).to be_present
    expect(payload[:temporal_options][:start_to_close_timeout]).to eq(120.0) # 2.minutes
    expect(payload[:temporal_options][:heartbeat_timeout]).to eq(10.0) # 10.seconds
  end

  context "when global timeout defaults are configured" do
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
      expect(TestJob.last_argument).to eq(123)

      # Verify workflow completed
      description = client.workflow_handle(workflow_id).describe
      expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
    ensure
      stop_worker(@worker_thread)
    end
  end

  private

  def start_worker(task_queue)
    Thread.new do
      worker = Temporalio::Worker.new(
        client: TemporalTestHelper.client,
        task_queue: task_queue,
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
end
