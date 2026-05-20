# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "securerandom"
require_relative "../fixtures/sample_jobs"

RSpec.describe "ActiveJob Temporal batch cancellation", :integration do
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal
    @workflow_ids = []

    example.run
  ensure
    cleanup_workflows
    ActiveJob::Base.queue_adapter = original_adapter
  end

  def client
    TemporalTestHelper.client
  end

  it "terminates running workflows matching search attributes" do
    task_queue = "batch-cancel-test-#{SecureRandom.hex(4)}"

    jobs = 2.times.map { LongRunningJob.set(queue: task_queue).perform_later }
    @workflow_ids = jobs.map { |job| ActiveJob::Temporal::Adapter.build_workflow_id(job) }
    @workflow_ids.each { |workflow_id| wait_for_workflow_running(workflow_id) }

    result = ActiveJob::Temporal.cancel_where(ajQueue: task_queue)

    expect(result).to eq(terminated: 2, failed: 0, errors: [])
    @workflow_ids.each { |workflow_id| wait_for_workflow_terminated(workflow_id) }
  end

  private

  def wait_for_workflow_running(workflow_id)
    wait_for_workflow_status(workflow_id, Temporalio::Client::WorkflowExecutionStatus::RUNNING)
  end

  def wait_for_workflow_terminated(workflow_id)
    wait_for_workflow_status(workflow_id, Temporalio::Client::WorkflowExecutionStatus::TERMINATED)
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
