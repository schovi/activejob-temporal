# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "temporalio/worker"
require "active_support/core_ext/numeric/time"
require_relative "../fixtures/sample_jobs"

RSpec.describe "ActiveJob Temporal scheduled jobs", :integration do
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

    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    job = TestJob.set(wait: 5.seconds).perform_later(42)
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

    sleep 1
    expect(TestJob.last_argument).to be_nil

    wait_for_result(42)

    expect(TestJob.last_argument).to eq(42)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
    expect(elapsed).to be >= 5

    handle = client.workflow_handle(workflow_id)
    description = handle.describe
    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)

    history = handle.fetch_history
    event_types = history.events.map(&:event_type)
    expect(event_types).to include(:EVENT_TYPE_TIMER_STARTED)
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
