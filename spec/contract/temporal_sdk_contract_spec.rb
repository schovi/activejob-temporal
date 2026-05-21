# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

RSpec.describe "Temporal Ruby SDK contract", :contract do
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal
    @workflow_ids = []
    TestJob.last_argument = nil
    TestState.instance.reset!

    example.run
  ensure
    cleanup_workflows
    stop_worker(@worker_thread)
    ActiveJob::Base.queue_adapter = original_adapter
    TestJob.last_argument = nil
    TestState.instance.reset!
  end

  def client
    TemporalTestHelper.client
  end

  it "connects to the configured namespace" do
    expect(client.namespace).to eq(TemporalTestHelper::TEST_NAMESPACE)
    expect(client.list_workflow_page(nil, page_size: 1).executions).to respond_to(:each)
  end

  it "executes workflows and activities with search attributes" do
    task_queue = "contract-execution-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    job = TestJob.set(queue: task_queue, tags: %w[contract sdk]).perform_later(42)
    workflow_id = record_workflow_id(job)

    wait_until { TestJob.last_argument == 42 }
    description = wait_for_terminal_status(workflow_id)

    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
    expect_search_attributes(description.search_attributes, job, task_queue)
  end

  it "applies retry policy attempts to activity execution" do
    task_queue = "contract-retry-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    job = RetryTestJob.set(queue: task_queue).perform_later
    workflow_id = record_workflow_id(job)

    wait_until { TestState.instance.test_result == "success" }
    description = wait_for_terminal_status(workflow_id)
    activity_started_event = activity_started_event_for(workflow_id)

    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
    expect(TestState.instance.attempt_count).to eq(2)
    expect(activity_started_event.activity_task_started_event_attributes.attempt).to eq(2)
  end

  it "cancels running workflow activities" do
    task_queue = "contract-cancel-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    job = LongRunningJob.set(queue: task_queue).perform_later
    workflow_id = record_workflow_id(job)

    wait_for_status(workflow_id, Temporalio::Client::WorkflowExecutionStatus::RUNNING)
    wait_until { TestState.instance.long_running_iterations.positive? }

    ActiveJob::Temporal.cancel(LongRunningJob, job.job_id)
    description = wait_for_status(workflow_id, Temporalio::Client::WorkflowExecutionStatus::CANCELED)

    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::CANCELED)
    expect(TestState.instance.long_running_completed).to be(false)
    expect(TestState.instance.long_running_iterations).to be < 10
  end

  private

  def start_worker(task_queue)
    @worker = Temporalio::Worker.new(
      client: client,
      task_queue: task_queue,
      workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
      activities: [
        ActiveJob::Temporal::Activities::DependencyStatusActivity,
        ActiveJob::Temporal::Activities::RateLimitActivity,
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

  def record_workflow_id(job)
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)
    @workflow_ids << workflow_id
    workflow_id
  end

  def wait_until
    Timeout.timeout(10) do
      loop do
        return if yield

        sleep 0.1
      end
    end
  end

  def wait_for_terminal_status(workflow_id)
    Timeout.timeout(10) do
      loop do
        description = client.workflow_handle(workflow_id).describe
        return description if terminal_statuses.include?(description.status)

        sleep 0.1
      end
    end
  end

  def wait_for_status(workflow_id, expected_status)
    Timeout.timeout(10) do
      loop do
        description = client.workflow_handle(workflow_id).describe
        return description if description.status == expected_status

        sleep 0.1
      end
    end
  end

  def activity_started_event_for(workflow_id)
    history = client.workflow_handle(workflow_id).fetch_history
    history.events.find { |event| event.event_type == :EVENT_TYPE_ACTIVITY_TASK_STARTED }
  end

  def expect_search_attributes(search_attributes, job, task_queue)
    expected_search_attributes(job, task_queue).each do |name, type, value|
      expect(search_attributes[search_attribute_key(name, type)]).to eq(value)
    end
    expect(search_attributes[search_attribute_key("ajEnqueuedAt", :TIME)]).to be_a(Time)
  end

  def expected_search_attributes(job, task_queue)
    [
      ["ajClass", :KEYWORD, "TestJob"],
      ["ajQueue", :KEYWORD, task_queue],
      ["ajJobId", :KEYWORD, job.job_id],
      ["ajTags", :KEYWORD_LIST, %w[contract sdk]]
    ]
  end

  def search_attribute_key(name, type)
    Temporalio::SearchAttributes::Key.new(name, Temporalio::SearchAttributes::IndexedValueType.const_get(type))
  end

  def terminal_statuses
    [
      Temporalio::Client::WorkflowExecutionStatus::COMPLETED,
      Temporalio::Client::WorkflowExecutionStatus::FAILED,
      Temporalio::Client::WorkflowExecutionStatus::CANCELED,
      Temporalio::Client::WorkflowExecutionStatus::TERMINATED,
      Temporalio::Client::WorkflowExecutionStatus::CONTINUED_AS_NEW,
      Temporalio::Client::WorkflowExecutionStatus::TIMED_OUT
    ]
  end

  def cleanup_workflows
    Array(@workflow_ids).each do |workflow_id|
      handle = client.workflow_handle(workflow_id)
      handle.terminate("ActiveJob::Temporal contract spec cleanup") if running?(handle)
    rescue StandardError
      nil
    end
  end

  def running?(handle)
    handle.describe.status == Temporalio::Client::WorkflowExecutionStatus::RUNNING
  end
end
