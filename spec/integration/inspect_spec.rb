# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

RSpec.describe "ActiveJob Temporal inspection", :integration do
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    original_workflow_id_generator = ActiveJob::Temporal.config.workflow_id_generator
    ActiveJob::Base.queue_adapter = :temporal
    TestState.instance.reset!
    TestJob.last_argument = nil
    @workflow_ids = []

    example.run
  ensure
    cleanup_workflows
    stop_worker(@worker_thread)
    TestState.instance.reset!
    TestJob.last_argument = nil
    ActiveJob::Temporal.config.workflow_id_generator = original_workflow_id_generator
    ActiveJob::Base.queue_adapter = original_adapter
  end

  def client
    TemporalTestHelper.client
  end

  it "reports running workflow status" do
    task_queue = "inspect-running-test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    job = TestJob.set(queue: task_queue, wait: 30.seconds).perform_later(42)
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)
    @workflow_ids << workflow_id
    wait_for_workflow_status(workflow_id, Temporalio::Client::WorkflowExecutionStatus::RUNNING)

    status = ActiveJob::Temporal.status(TestJob, job.job_id)

    expect(status[:state]).to eq(:running)
    expect(status[:workflow_id]).to eq(workflow_id)
    expect(status[:run_id]).to be_a(String)
    expect(status[:started_at]).to be_a(Time)
    expect(ActiveJob::Temporal.running?(TestJob, job.job_id)).to be(true)
  end

  it "reports completed workflow status" do
    task_queue = "inspect-completed-test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    job = TestJob.set(queue: task_queue).perform_later(42)
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)
    @workflow_ids << workflow_id
    wait_for_workflow_status(workflow_id, Temporalio::Client::WorkflowExecutionStatus::COMPLETED)

    status = ActiveJob::Temporal.status(TestJob, job.job_id)

    expect(status[:state]).to eq(:completed)
    expect(status[:closed_at]).to be_a(Time)
    expect(ActiveJob::Temporal.completed?(TestJob, job.job_id)).to be(true)
  end

  it "reports failed workflow status" do
    task_queue = "inspect-failed-test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    job = DiscardTestJob.set(queue: task_queue).perform_later
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)
    @workflow_ids << workflow_id
    wait_for_workflow_status(workflow_id, Temporalio::Client::WorkflowExecutionStatus::FAILED)

    status = ActiveJob::Temporal.status(DiscardTestJob, job.job_id)

    expect(status[:state]).to eq(:failed)
    expect(status[:closed_at]).to be_a(Time)
    expect(ActiveJob::Temporal.failed?(DiscardTestJob, job.job_id)).to be(true)
  end

  it "reports status for workflows with custom workflow IDs" do
    task_queue = "inspect-custom-id-test-#{SecureRandom.hex(4)}"
    ActiveJob::Temporal.config.workflow_id_generator = lambda do |job|
      "tenant-42:ajwf:#{job.class.name}:#{job.job_id}"
    end
    ActiveJob::Base.queue_adapter = :temporal

    @worker_thread = start_worker(task_queue)
    sleep 0.5

    job = TestJob.set(queue: task_queue).perform_later(42)
    workflow_id = "tenant-42:ajwf:#{TestJob.name}:#{job.job_id}"
    @workflow_ids << workflow_id
    wait_for_workflow_status(workflow_id, Temporalio::Client::WorkflowExecutionStatus::COMPLETED)

    status = wait_for_status(TestJob, job.job_id, :completed)

    expect(status[:state]).to eq(:completed)
    expect(status[:workflow_id]).to eq(workflow_id)
    expect(ActiveJob::Temporal.completed?(TestJob, job.job_id)).to be(true)
  end

  it "returns nil for missing workflows" do
    job_id = SecureRandom.uuid

    expect(ActiveJob::Temporal.status(TestJob, job_id)).to be_nil
    expect(ActiveJob::Temporal.running?(TestJob, job_id)).to be(false)
  end

  private

  def start_worker(task_queue)
    @worker = Temporalio::Worker.new(
      client: TemporalTestHelper.client,
      task_queue: task_queue,
      workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
      activities: [ActiveJob::Temporal::Activities::AjRunnerActivity]
    )

    Thread.new { @worker.run }
  end

  def stop_worker(thread)
    return unless thread&.alive?

    thread.kill
    thread.join(5)
  end

  def wait_for_workflow_status(workflow_id, expected_status)
    Timeout.timeout(5) do
      loop do
        status = client.workflow_handle(workflow_id).describe.status
        break if status == expected_status

        sleep 0.1
      end
    end
  end

  def wait_for_status(job_class, job_id, expected_state)
    Timeout.timeout(5) do
      loop do
        status = ActiveJob::Temporal.status(job_class, job_id)
        return status if status&.fetch(:state) == expected_state

        sleep 0.1
      end
    end
  end

  def cleanup_workflows
    Array(@workflow_ids).each do |workflow_id|
      handle = client.workflow_handle(workflow_id)
      handle.terminate("ActiveJob::Temporal test cleanup") if running?(handle)
    rescue StandardError
      nil
    end
  end

  def running?(handle)
    handle.describe.status == Temporalio::Client::WorkflowExecutionStatus::RUNNING
  end
end
