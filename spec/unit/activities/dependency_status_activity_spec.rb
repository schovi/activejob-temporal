# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::Activities::DependencyStatusActivity do
  subject(:activity) { described_class.new }

  let(:client_class) do
    Class.new do
      def workflow_handle(_workflow_id, run_id: nil); end
      def list_workflows(_query); end
    end
  end
  let(:handle_class) do
    Class.new do
      def describe; end
    end
  end
  let(:client) { instance_double(client_class) }
  let(:handle) { instance_double(handle_class) }
  let(:run_id) { "run-1" }

  before do
    allow(ActiveJob::Temporal).to receive(:client).and_return(client)
  end

  it "returns completed status for an explicit workflow ID" do
    description = workflow_description(
      workflow_id: "ajwf:DependencyParentJob:parent-123",
      status: Temporalio::Client::WorkflowExecutionStatus::COMPLETED
    )
    allow(client).to receive(:workflow_handle)
      .with("ajwf:DependencyParentJob:parent-123", run_id: nil)
      .and_return(handle)
    allow(handle).to receive(:describe).and_return(description)

    result = activity.execute([{ "workflow_id" => "ajwf:DependencyParentJob:parent-123" }])

    expect(result).to eq([
                           {
                             "workflow_id" => "ajwf:DependencyParentJob:parent-123",
                             "run_id" => run_id,
                             "state" => "completed"
                           }
                         ])
  end

  it "finds dependencies by search attributes when only a job ID is available" do
    workflow = double("WorkflowExecution", id: "ajwf:DependencyParentJob:parent-123", run_id: run_id)
    description = workflow_description(
      workflow_id: "ajwf:DependencyParentJob:parent-123",
      status: Temporalio::Client::WorkflowExecutionStatus::RUNNING
    )
    allow(client).to receive(:list_workflows).with("ajJobId='parent-123'").and_return([workflow])
    allow(client).to receive(:workflow_handle)
      .with("ajwf:DependencyParentJob:parent-123", run_id: run_id)
      .and_return(handle)
    allow(handle).to receive(:describe).and_return(description)

    result = activity.execute([{ "job_id" => "parent-123" }])

    expect(result).to eq([
                           {
                             "job_id" => "parent-123",
                             "workflow_id" => "ajwf:DependencyParentJob:parent-123",
                             "run_id" => run_id,
                             "state" => "running"
                           }
                         ])
  end

  it "falls back to the default workflow ID for class-qualified dependencies" do
    description = workflow_description(
      workflow_id: "ajwf:DependencyParentJob:parent-123",
      status: Temporalio::Client::WorkflowExecutionStatus::FAILED
    )
    allow(client).to receive(:list_workflows)
      .with("ajClass='DependencyParentJob' AND ajJobId='parent-123'")
      .and_return([])
    allow(client).to receive(:workflow_handle)
      .with("ajwf:DependencyParentJob:parent-123", run_id: nil)
      .and_return(handle)
    allow(handle).to receive(:describe).and_return(description)

    result = activity.execute([{ "job_class" => "DependencyParentJob", "job_id" => "parent-123" }])

    expect(result.first).to include(
      "job_class" => "DependencyParentJob",
      "job_id" => "parent-123",
      "workflow_id" => "ajwf:DependencyParentJob:parent-123",
      "state" => "failed"
    )
  end

  it "returns not_found when no workflow can be resolved" do
    allow(client).to receive(:list_workflows).with("ajJobId='missing-parent'").and_return([])

    result = activity.execute([{ "job_id" => "missing-parent" }])

    expect(result).to eq([
                           {
                             "job_id" => "missing-parent",
                             "state" => "not_found"
                           }
                         ])
  end

  it "returns not_found when Temporal reports a missing workflow" do
    not_found_error = Temporalio::Error::RPCError.new(
      "not found",
      code: Temporalio::Error::RPCError::Code::NOT_FOUND,
      raw_grpc_status: nil
    )
    allow(client).to receive(:workflow_handle)
      .with("ajwf:DependencyParentJob:parent-123", run_id: nil)
      .and_return(handle)
    allow(handle).to receive(:describe).and_raise(not_found_error)

    result = activity.execute([{ "workflow_id" => "ajwf:DependencyParentJob:parent-123" }])

    expect(result.first).to include(
      "workflow_id" => "ajwf:DependencyParentJob:parent-123",
      "state" => "not_found"
    )
  end

  it "falls back to search attributes when a default workflow ID misses" do
    not_found_error = Temporalio::Error::RPCError.new(
      "not found",
      code: Temporalio::Error::RPCError::Code::NOT_FOUND,
      raw_grpc_status: nil
    )
    workflow = double("WorkflowExecution", id: "custom:parent-123", run_id: run_id)
    description = workflow_description(
      workflow_id: "custom:parent-123",
      status: Temporalio::Client::WorkflowExecutionStatus::COMPLETED
    )

    allow(client).to receive(:workflow_handle)
      .with("ajwf:DependencyParentJob:parent-123", run_id: nil)
      .and_return(handle)
    allow(handle).to receive(:describe).and_raise(not_found_error)
    allow(client).to receive(:list_workflows)
      .with("ajClass='DependencyParentJob' AND ajJobId='parent-123'")
      .and_return([workflow])
    fallback_handle = instance_double(handle_class)
    allow(client).to receive(:workflow_handle)
      .with("custom:parent-123", run_id: run_id)
      .and_return(fallback_handle)
    allow(fallback_handle).to receive(:describe).and_return(description)

    result = activity.execute([
                                {
                                  "job_class" => "DependencyParentJob",
                                  "job_id" => "parent-123",
                                  "workflow_id" => "ajwf:DependencyParentJob:parent-123"
                                }
                              ])

    expect(result.first).to include(
      "workflow_id" => "custom:parent-123",
      "state" => "completed"
    )
  end

  def workflow_description(workflow_id:, status:)
    double(
      "WorkflowDescription",
      id: workflow_id,
      run_id: run_id,
      status: status
    )
  end
end
