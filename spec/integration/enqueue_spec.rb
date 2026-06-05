# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/worker_runtime"
require "timeout"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

describe "ActiveJob Temporal enqueue", :integration do
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

  it "executes an enqueued job immediately via Temporal" do
    task_queue = "test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    job = TestJob.set(queue: task_queue, tags: %w[urgent customer_123]).perform_later(42)
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

    wait_for_result(42)

    assert_equal 42, TestJob.last_argument

    description = wait_for_workflow_terminal_status(workflow_id)
    assert_equal Temporalio::Client::WorkflowExecutionStatus::COMPLETED, description.status
  ensure
    stop_worker(@worker_thread)
  end

  it "attaches search attributes to workflows for filtering and debugging" do
    task_queue = "test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    job = TestJob.set(queue: task_queue, tags: %w[urgent customer_123]).perform_later(42)
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

    wait_for_result(42)

    # Verify job executed
    assert_equal 42, TestJob.last_argument

    # Query workflow description to access search attributes
    description = wait_for_workflow_terminal_status(workflow_id)

    # Verify workflow completed
    assert_equal Temporalio::Client::WorkflowExecutionStatus::COMPLETED, description.status

    # Access search attributes
    search_attrs = description.search_attributes

    # Create typed keys for querying
    aj_class_key = Temporalio::SearchAttributes::Key.new("ajClass", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)
    aj_queue_key = Temporalio::SearchAttributes::Key.new("ajQueue", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)
    aj_job_id_key = Temporalio::SearchAttributes::Key.new("ajJobId", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)
    aj_enqueued_at_key = Temporalio::SearchAttributes::Key.new("ajEnqueuedAt", Temporalio::SearchAttributes::IndexedValueType::TIME)
    aj_tags_key = Temporalio::SearchAttributes::Key.new("ajTags", Temporalio::SearchAttributes::IndexedValueType::KEYWORD_LIST)

    # Verify search attributes
    assert_equal "TestJob", search_attrs[aj_class_key]
    assert_equal task_queue, search_attrs[aj_queue_key]
    assert_equal job.job_id, search_attrs[aj_job_id_key]
    assert_equal %w[urgent customer_123], search_attrs[aj_tags_key]

    # Verify ajEnqueuedAt is a recent timestamp
    enqueued_at = search_attrs[aj_enqueued_at_key]
    assert_instance_of Time, enqueued_at
    assert_in_delta Time.now, enqueued_at, 10

    # Verify ajTenantId is not present (since job argument is an integer, not a tenant object)
    aj_tenant_id_key = Temporalio::SearchAttributes::Key.new("ajTenantId", Temporalio::SearchAttributes::IndexedValueType::INTEGER)
    assert_nil search_attrs[aj_tenant_id_key]
  ensure
    stop_worker(@worker_thread)
  end

  it "sends workflow updates to a running job and returns the update result" do
    task_queue = "test-updates-#{SecureRandom.hex(4)}"
    job_class = stub_const("WorkflowUpdateIntegrationJob", Class.new(ActiveJob::Base) do
      queue_as :default

      temporal_update :set_progress do |state, completed, total|
        state["progress"] = { "completed" => completed, "total" => total }
      end

      temporal_query :progress do |state|
        state["progress"]
      end

      def perform
        sleep 2
      end
    end)
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    job = job_class.set(queue: task_queue).perform_later
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)
    wait_for_workflow_status(workflow_id, Temporalio::Client::WorkflowExecutionStatus::RUNNING)

    result = ActiveJob::Temporal.update(job_class, job.job_id, :set_progress, 3, 10)

    assert_equal({ "completed" => 3, "total" => 10 }, result)
    assert_equal({ "completed" => 3, "total" => 10 }, ActiveJob::Temporal.query(job_class, job.job_id, :progress))
  ensure
    stop_worker(@worker_thread)
  end

  describe "large payloads" do
    it "rejects job with payload > 250KB (default limit)" do
      # Create a large argument that exceeds the default 250KB limit
      large_argument = "x" * (251 * 1024)
      job_class = stub_const("OversizedPayloadJob", Class.new(ActiveJob::Base) do
        def perform(arg)
          # Job logic
        end
      end)

      ActiveJob::Base.queue_adapter = :temporal

      error = assert_raises(ActiveJob::SerializationError) do
        job_class.perform_later(large_argument)
      end

      assert_match(/exceeds maximum allowed size/, error.message)
    end

    it "accepts job with payload < 250KB (default limit)" do
      task_queue = "test-#{SecureRandom.hex(4)}"
      @worker_thread = start_worker(task_queue)
      sleep 0.5

      # Create a payload under the limit
      small_argument = "x" * (100 * 1024) # 100 KB
      job_class = stub_const("AcceptedPayloadJob", Class.new(ActiveJob::Base) do
        @last_executed = nil

        class << self
          attr_accessor :last_executed
        end

        def perform(arg)
          self.class.last_executed = arg.length
        end
      end)

      job_class.set(queue: task_queue).perform_later(small_argument)

      Timeout.timeout(10) do
        loop do
          break if job_class.last_executed.present?

          sleep 0.1
        end
      end

      assert_equal 100 * 1024, job_class.last_executed
    ensure
      stop_worker(@worker_thread)
    end

    it "respects custom max_payload_size_kb configuration" do
      # Configure a custom smaller limit
      ActiveJob::Temporal.configure do |config|
        config.max_payload_size_kb = 10
      end

      # Create a payload between 10KB and 250KB
      medium_argument = "y" * (15 * 1024) # 15 KB
      job_class = stub_const("CustomPayloadLimitJob", Class.new(ActiveJob::Base) do
        def perform(arg)
          # Job logic
        end
      end)

      ActiveJob::Base.queue_adapter = :temporal

      error = assert_raises(ActiveJob::SerializationError) do
        job_class.perform_later(medium_argument)
      end

      assert_match(/exceeds maximum allowed size/, error.message)
    ensure
      # Reset to default
      ActiveJob::Temporal.configure do |config|
        config.max_payload_size_kb = 250
      end
    end
  end

  private

  def start_worker(task_queue = "default")
    start_temporal_worker(task_queue)
  end

  def stop_worker(thread)
    stop_temporal_worker(thread)
  end

  def wait_for_result(expected)
    Timeout.timeout(10) do
      loop do
        break if TestJob.last_argument == expected

        sleep 0.1
      end
    end
  end

  def wait_for_workflow_terminal_status(workflow_id)
    handle = client.workflow_handle(workflow_id)
    terminal_statuses = [
      Temporalio::Client::WorkflowExecutionStatus::COMPLETED,
      Temporalio::Client::WorkflowExecutionStatus::FAILED,
      Temporalio::Client::WorkflowExecutionStatus::CANCELED,
      Temporalio::Client::WorkflowExecutionStatus::TERMINATED,
      Temporalio::Client::WorkflowExecutionStatus::CONTINUED_AS_NEW,
      Temporalio::Client::WorkflowExecutionStatus::TIMED_OUT
    ]

    Timeout.timeout(10) do
      loop do
        description = handle.describe
        return description if terminal_statuses.include?(description.status)

        sleep 0.1
      end
    end
  end

  def wait_for_workflow_status(workflow_id, expected_status)
    handle = client.workflow_handle(workflow_id)

    Timeout.timeout(10) do
      loop do
        break if handle.describe.status == expected_status

        sleep 0.1
      end
    end
  end
end
