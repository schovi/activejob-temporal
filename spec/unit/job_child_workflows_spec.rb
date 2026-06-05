# frozen_string_literal: true

require "spec_helper"
require "active_job"

describe "ActiveJob Temporal child workflows" do
  let(:queue_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "ChildWorkflowRootJob"

      def perform(*) = nil
    end
  end
  let(:child_job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "ChildWorkflowChildJob"

      def perform(*) = nil
    end
  end
  let(:final_job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "ChildWorkflowFinalJob"

      def perform(*) = nil
    end
  end

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = queue_adapter

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "captures child workflows configured through Temporal job descriptors" do
    configured_final_child = ActiveJob::Temporal.job(
      final_job_class,
      queue: "reporting",
      priority: 7,
      tags: %i[fanout urgent]
    )

    job = job_class.set(child_workflows: [child_job_class, configured_final_child]).perform_later("seed")
    expected_child_workflows = [
      {
        job_class: "ChildWorkflowChildJob",
        options: {}
      },
      {
        job_class: "ChildWorkflowFinalJob",
        options: {
          queue: "reporting",
          priority: 7,
          tags: %w[fanout urgent]
        }
      }
    ]

    assert_equal expected_child_workflows, job.temporal_child_workflows
    assert_equal 1, queue_adapter.enqueued_jobs.size
  end

  it "supports ActiveJob configured jobs as a warned compatibility fallback" do
    logger_warnings = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
    configured_final_child = final_job_class.set(queue: "reporting", priority: 7, tags: %i[fanout urgent])

    job = job_class.set(child_workflows: [configured_final_child]).perform_later("seed")
    expected_child_workflows = [
      {
        job_class: "ChildWorkflowFinalJob",
        options: {
          queue: "reporting",
          priority: 7,
          tags: %w[fanout urgent]
        }
      }
    ]

    assert_equal expected_child_workflows, job.temporal_child_workflows
    assert_private_api_warning logger_warnings, "child_workflows"
  end

  it "captures external Temporal workflow refs in child workflow order" do
    shipment_workflow = ActiveJob::Temporal.workflow(
      "fulfillment.PrepareShipmentWorkflow",
      task_queue: "fulfillment-kotlin",
      run_timeout: 5.minutes
    )

    job = job_class.set(child_workflows: [child_job_class, shipment_workflow]).perform_later("seed")
    expected_child_workflows = [
      {
        job_class: "ChildWorkflowChildJob",
        options: {}
      },
      {
        temporal_operation: "workflow",
        temporal_type: "fulfillment.PrepareShipmentWorkflow",
        options: {
          task_queue: "fulfillment-kotlin",
          run_timeout: 300.0
        }
      }
    ]

    assert_equal expected_child_workflows, job.temporal_child_workflows
  end

  it "captures child workflows configured on a job instance" do
    job = job_class.new

    job.set(child_workflows: [child_job_class])
    expected_child_workflows = [
      {
        job_class: "ChildWorkflowChildJob",
        options: {}
      }
    ]

    assert_equal expected_child_workflows, job.temporal_child_workflows
  end

  it "rejects a non-array child workflow value" do
    job = job_class.new

    error = assert_raises(ArgumentError) { job.set(child_workflows: child_job_class) }
    assert_match(/child_workflows must be an Array/, error.message)
  end

  it "rejects child workflow entries that are not ActiveJob classes or configured jobs" do
    job = job_class.new

    error = assert_raises(ArgumentError) { job.set(child_workflows: [Object.new]) }
    assert_match(/child_workflows entries must be ActiveJob classes or configured jobs/, error.message)
  end

  it "rejects configured child workflows with unsupported ActiveJob options" do
    job = job_class.new

    error = assert_raises(ArgumentError) do
      job.set(child_workflows: [ActiveJob::Temporal.job(child_job_class, wait: 5)])
    end
    assert_match(/only support queue, priority, and tags options/, error.message)
  end

  it "rejects external Temporal activity refs in child_workflows" do
    job = job_class.new
    activity = ActiveJob::Temporal.activity("payments.AuthorizePayment", task_queue: "payments-kotlin")

    error = assert_raises(ArgumentError) { job.set(child_workflows: [activity]) }
    assert_match(/external refs must be workflows/, error.message)
  end

  def assert_private_api_warning(logger_warnings, feature)
    warning = logger_warnings.calls_for(:warn).find do |call|
      call.arguments == ["active_job_configured_job_private_api"] && call.keywords[:feature] == feature
    end

    refute_nil warning
  end
end
