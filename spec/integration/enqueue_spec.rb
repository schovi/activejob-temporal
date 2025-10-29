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

  it "attaches search attributes to workflows for filtering and debugging" do
    job = TestJob.perform_later(42)
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

    @worker_thread = start_worker

    wait_for_result(42)

    # Verify job executed
    expect(TestJob.last_argument).to eq(42)

    # Query workflow description to access search attributes
    handle = client.workflow_handle(workflow_id)
    description = handle.describe

    # Verify workflow completed
    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)

    # Access search attributes
    search_attrs = description.search_attributes

    # Create typed keys for querying
    aj_class_key = Temporalio::SearchAttributes::Key.new("ajClass", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)
    aj_queue_key = Temporalio::SearchAttributes::Key.new("ajQueue", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)
    aj_job_id_key = Temporalio::SearchAttributes::Key.new("ajJobId", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)
    aj_enqueued_at_key = Temporalio::SearchAttributes::Key.new("ajEnqueuedAt", Temporalio::SearchAttributes::IndexedValueType::TIME)

    # Verify search attributes
    expect(search_attrs[aj_class_key]).to eq("TestJob")
    expect(search_attrs[aj_queue_key]).to eq("default")
    expect(search_attrs[aj_job_id_key]).to eq(job.job_id)

    # Verify ajEnqueuedAt is a recent timestamp
    enqueued_at = search_attrs[aj_enqueued_at_key]
    expect(enqueued_at).to be_a(Time)
    expect(enqueued_at).to be_within(10).of(Time.now)

    # Verify ajTenantId is not present (since job argument is an integer, not a tenant object)
    aj_tenant_id_key = Temporalio::SearchAttributes::Key.new("ajTenantId", Temporalio::SearchAttributes::IndexedValueType::INTEGER)
    expect(search_attrs[aj_tenant_id_key]).to be_nil
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
