# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "securerandom"
require "temporalio/worker"

RSpec.describe "ActiveJob Temporal child workflows", :integration do
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

  it "starts child workflows and passes their result collection to the parent chain" do
    stub_const("ChildWorkflowParentIntegrationJob", Class.new(ActiveJob::Base) do
      def perform(seed)
        "parent:#{seed}"
      end
    end)
    stub_const("ChildWorkflowChildIntegrationJob", Class.new(ActiveJob::Base) do
      def perform(parent_result)
        TestState.instance.test_result ||= []
        TestState.instance.test_result << "child:#{parent_result}"
        "child-result"
      end
    end)
    stub_const("ChildWorkflowChainIntegrationJob", Class.new(ActiveJob::Base) do
      def perform(result_collection)
        TestState.instance.test_result ||= []
        TestState.instance.test_result << result_collection
        "chain-result"
      end
    end)

    task_queue = "child-workflow-test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    parent_job = ChildWorkflowParentIntegrationJob
                 .set(
                   queue: task_queue,
                   child_workflows: [
                     ActiveJob::Temporal.job(ChildWorkflowChildIntegrationJob, queue: task_queue)
                   ],
                   chain: [
                     ActiveJob::Temporal.job(ChildWorkflowChainIntegrationJob, queue: task_queue)
                   ]
                 )
                 .perform_later("seed")
    @workflow_ids << ActiveJob::Temporal::Adapter.build_workflow_id(parent_job)
    @workflow_ids << "ajwf:ChildWorkflowChildIntegrationJob:#{parent_job.job_id}:child:1"

    result_collection = wait_for_result_collection

    expect(TestState.instance.test_result).to include("child:parent:seed")
    expect(result_collection["parent_result"]).to eq("parent:seed")
    expect(result_collection["child_results"]).to contain_exactly(
      hash_including(
        "job_class" => "ChildWorkflowChildIntegrationJob",
        "job_id" => "#{parent_job.job_id}:child:1",
        "result" => "child-result"
      )
    )
  end

  it "starts multiple child workflows before passing their results to the parent chain" do
    stub_const("ChildWorkflowFanoutParentIntegrationJob", Class.new(ActiveJob::Base) do
      def perform(seed)
        "parent:#{seed}"
      end
    end)
    stub_const("ChildWorkflowFirstChildIntegrationJob", Class.new(ActiveJob::Base) do
      def perform(parent_result)
        TestState.instance.test_result ||= []
        TestState.instance.test_result << "first_child:#{parent_result}"
        "first-child-result"
      end
    end)
    stub_const("ChildWorkflowSecondChildIntegrationJob", Class.new(ActiveJob::Base) do
      def perform(parent_result)
        TestState.instance.test_result ||= []
        TestState.instance.test_result << "second_child:#{parent_result}"
        "second-child-result"
      end
    end)
    stub_const("ChildWorkflowFanoutReducerIntegrationJob", Class.new(ActiveJob::Base) do
      def perform(result_collection)
        child_results = result_collection.fetch("child_results").map { |result| result.fetch("result") }
        TestState.instance.test_result ||= []
        TestState.instance.test_result << "reducer:#{child_results.sort.join(',')}"
        TestState.instance.test_result << result_collection
        result_collection
      end
    end)

    task_queue = "child-workflow-fanout-test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    parent_job = ChildWorkflowFanoutParentIntegrationJob
                 .set(
                   queue: task_queue,
                   child_workflows: [
                     ActiveJob::Temporal.job(ChildWorkflowFirstChildIntegrationJob, queue: task_queue),
                     ActiveJob::Temporal.job(ChildWorkflowSecondChildIntegrationJob, queue: task_queue)
                   ],
                   chain: [
                     ActiveJob::Temporal.job(ChildWorkflowFanoutReducerIntegrationJob, queue: task_queue)
                   ]
                 )
                 .perform_later("seed")
    @workflow_ids << ActiveJob::Temporal::Adapter.build_workflow_id(parent_job)
    @workflow_ids << "ajwf:ChildWorkflowFirstChildIntegrationJob:#{parent_job.job_id}:child:1"
    @workflow_ids << "ajwf:ChildWorkflowSecondChildIntegrationJob:#{parent_job.job_id}:child:2"

    wait_for_sequence("reducer:first-child-result,second-child-result")

    sequence = TestState.instance.test_result
    reducer_index = sequence.index("reducer:first-child-result,second-child-result")
    expect(sequence.index("first_child:parent:seed")).to be < reducer_index
    expect(sequence.index("second_child:parent:seed")).to be < reducer_index

    result_collection = wait_for_result_collection
    expect(result_collection["child_results"]).to contain_exactly(
      hash_including(
        "job_class" => "ChildWorkflowFirstChildIntegrationJob",
        "job_id" => "#{parent_job.job_id}:child:1",
        "result" => "first-child-result"
      ),
      hash_including(
        "job_class" => "ChildWorkflowSecondChildIntegrationJob",
        "job_id" => "#{parent_job.job_id}:child:2",
        "result" => "second-child-result"
      )
    )
  end

  private

  def start_worker(task_queue)
    @worker = Temporalio::Worker.new(
      client: TemporalTestHelper.client,
      task_queue: task_queue,
      workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
      activities: [
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

  def wait_for_result_collection
    Timeout.timeout(10) do
      loop do
        result = Array(TestState.instance.test_result).find { |entry| entry.is_a?(Hash) }
        return result if result

        sleep 0.1
      end
    end
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
