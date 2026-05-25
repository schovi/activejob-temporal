# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe "ActiveJob Temporal child workflows" do
  let(:test_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
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
    ActiveJob::Base.queue_adapter = test_adapter

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "captures child workflows configured through ActiveJob.set" do
    configured_final_child = final_job_class.set(queue: "reporting", priority: 7, tags: %i[fanout urgent])

    job = job_class.set(child_workflows: [child_job_class, configured_final_child]).perform_later("seed")

    expect(job.temporal_child_workflows).to eq([
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
                                               ])
    expect(test_adapter.enqueued_jobs.size).to eq(1)
  end

  it "captures external Temporal workflow refs in child workflow order" do
    shipment_workflow = ActiveJob::Temporal.workflow(
      "fulfillment.PrepareShipmentWorkflow",
      task_queue: "fulfillment-kotlin",
      run_timeout: 5.minutes
    )

    job = job_class.set(child_workflows: [child_job_class, shipment_workflow]).perform_later("seed")

    expect(job.temporal_child_workflows).to eq([
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
                                               ])
  end

  it "captures child workflows configured on a job instance" do
    job = job_class.new

    job.set(child_workflows: [child_job_class])

    expect(job.temporal_child_workflows).to eq([
                                                 {
                                                   job_class: "ChildWorkflowChildJob",
                                                   options: {}
                                                 }
                                               ])
  end

  it "rejects a non-array child workflow value" do
    job = job_class.new

    expect { job.set(child_workflows: child_job_class) }
      .to raise_error(ArgumentError, /child_workflows must be an Array/)
  end

  it "rejects child workflow entries that are not ActiveJob classes or configured jobs" do
    job = job_class.new

    expect { job.set(child_workflows: [Object.new]) }
      .to raise_error(ArgumentError, /child_workflows entries must be ActiveJob classes or configured jobs/)
  end

  it "rejects configured child workflows with unsupported ActiveJob options" do
    job = job_class.new

    expect { job.set(child_workflows: [child_job_class.set(wait: 5)]) }
      .to raise_error(ArgumentError, /only support queue, priority, and tags options/)
  end

  it "rejects external Temporal activity refs in child_workflows" do
    job = job_class.new
    activity = ActiveJob::Temporal.activity("payments.AuthorizePayment", task_queue: "payments-kotlin")

    expect { job.set(child_workflows: [activity]) }
      .to raise_error(ArgumentError, /external refs must be workflows/)
  end
end
