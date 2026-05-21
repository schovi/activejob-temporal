# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "securerandom"
require "temporalio/worker"

RSpec.describe "ActiveJob Temporal job dependencies", :integration do
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal
    TestState.instance.reset!
    @workflow_ids = []

    example.run
  ensure
    cleanup_workflows
    stop_worker(@worker_thread)
    TestState.instance.reset!
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "waits for parent jobs before executing dependent jobs" do
    stub_const("DependencyParentIntegrationJob", Class.new(ActiveJob::Base) do
      def perform
        TestState.instance.test_result ||= []
        TestState.instance.test_result << "parent_started"
        sleep 0.3
        TestState.instance.test_result << "parent_completed"
      end
    end)
    stub_const("DependencyChildIntegrationJob", Class.new(ActiveJob::Base) do
      def perform
        TestState.instance.test_result ||= []
        TestState.instance.test_result << "child_started"
      end
    end)
    stub_const("ActiveJob::Temporal::Workflows::WorkflowDependencies::DEPENDENCY_WAIT_INTERVAL", 0.1)

    task_queue = "dependency-test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    parent_job = DependencyParentIntegrationJob.set(queue: task_queue).perform_later
    child_job = DependencyChildIntegrationJob.set(queue: task_queue, depends_on: parent_job).perform_later
    @workflow_ids << ActiveJob::Temporal::Adapter.build_workflow_id(parent_job)
    @workflow_ids << ActiveJob::Temporal::Adapter.build_workflow_id(child_job)

    wait_for_sequence("child_started")

    sequence = TestState.instance.test_result
    expect(sequence.index("parent_completed")).to be < sequence.index("child_started")
  end

  private

  def start_worker(task_queue)
    @worker = Temporalio::Worker.new(
      client: TemporalTestHelper.client,
      task_queue: task_queue,
      workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
      activities: [
        ActiveJob::Temporal::Activities::DependencyStatusActivity,
        ActiveJob::Temporal::Activities::AjRunnerActivity
      ]
    )

    Thread.new { @worker.run }
  end

  def stop_worker(thread)
    return unless thread&.alive?

    thread.kill
    thread.join(5)
  end

  def wait_for_sequence(value)
    Timeout.timeout(10) do
      loop do
        sequence = TestState.instance.test_result || []
        return if sequence.include?(value)

        sleep 0.1
      end
    end
  end

  def cleanup_workflows
    Array(@workflow_ids).each do |workflow_id|
      handle = TemporalTestHelper.client.workflow_handle(workflow_id)
      handle.terminate("ActiveJob::Temporal test cleanup") if running?(handle)
    rescue StandardError
      nil
    end
  end

  def running?(handle)
    handle.describe.status == Temporalio::Client::WorkflowExecutionStatus::RUNNING
  end
end
