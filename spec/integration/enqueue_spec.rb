# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

RSpec.describe "ActiveJob Temporal enqueue", :integration do
  let(:client) { TemporalTestHelper.client }

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

  it "executes an enqueued job immediately via Temporal" do
    job = TestJob.perform_later(42)
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

    @worker_thread = start_worker

    wait_for_result(42)

    expect(TestJob.last_argument).to eq(42)

    description = client.workflow_handle(workflow_id).describe
    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
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
        break if TestJob.last_argument == expected

        sleep 0.1
      end
    end
  end
end
