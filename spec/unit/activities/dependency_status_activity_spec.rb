# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/activities/dependency_status_activity"

module DependencyStatusActivitySpecSupport
  Workflow = Struct.new(:id, :run_id, keyword_init: true)
  Description = Struct.new(:id, :run_id, :status, keyword_init: true)

  class Handle
    def initialize(description: nil, error: nil)
      @description = description
      @error = error
    end

    def describe
      raise @error if @error

      @description
    end
  end

  class FakeClient
    def initialize
      @handles = {}
      @list_results = {}
    end

    def workflow_handle(workflow_id, run_id: nil)
      @handles.fetch([workflow_id, run_id])
    end

    def list_workflows(query)
      result = @list_results.fetch(query)
      raise result if result.is_a?(Exception)

      result
    end

    def stub_workflow_handle(workflow_id, run_id:, handle:)
      @handles[[workflow_id, run_id]] = handle
    end

    def stub_list_workflows(query, result)
      @list_results[query] = result
    end
  end
end

describe ActiveJob::Temporal::Activities::DependencyStatusActivity do
  let(:activity) { described_class.new }

  let(:client) { DependencyStatusActivitySpecSupport::FakeClient.new }
  let(:run_id) { "run-1" }

  before do
    call_recorded_method(ActiveJob::Temporal, :client, returns: client)
  end

  it "returns completed status for an explicit workflow ID" do
    stub_workflow_handle(
      "ajwf:DependencyParentJob:parent-123",
      description: workflow_description(
        workflow_id: "ajwf:DependencyParentJob:parent-123",
        status: Temporalio::Client::WorkflowExecutionStatus::COMPLETED
      )
    )

    result = activity.execute([{ "workflow_id" => "ajwf:DependencyParentJob:parent-123" }])

    assert_equal [
      {
        "workflow_id" => "ajwf:DependencyParentJob:parent-123",
        "run_id" => run_id,
        "state" => "completed"
      }
    ], result
  end

  it "finds dependencies by search attributes when only a job ID is available" do
    stub_list_workflows(
      "ajJobId='parent-123' ORDER BY StartTime DESC",
      [workflow("ajwf:DependencyParentJob:parent-123")]
    )
    stub_workflow_handle(
      "ajwf:DependencyParentJob:parent-123",
      run_id: run_id,
      description: workflow_description(
        workflow_id: "ajwf:DependencyParentJob:parent-123",
        status: Temporalio::Client::WorkflowExecutionStatus::RUNNING
      )
    )

    result = activity.execute([{ "job_id" => "parent-123" }])

    assert_equal [
      {
        "job_id" => "parent-123",
        "workflow_id" => "ajwf:DependencyParentJob:parent-123",
        "run_id" => run_id,
        "state" => "running"
      }
    ], result
  end

  it "falls back to unordered search when ordered visibility queries are unsupported" do
    stub_list_workflows("ajJobId='parent-123' ORDER BY StartTime DESC", invalid_argument_error)
    stub_list_workflows("ajJobId='parent-123'", [workflow("ajwf:DependencyParentJob:parent-123")])
    stub_workflow_handle(
      "ajwf:DependencyParentJob:parent-123",
      run_id: run_id,
      description: workflow_description(
        workflow_id: "ajwf:DependencyParentJob:parent-123",
        status: Temporalio::Client::WorkflowExecutionStatus::RUNNING
      )
    )

    result = activity.execute([{ "job_id" => "parent-123" }])

    assert_hash_includes(
      {
        "job_id" => "parent-123",
        "workflow_id" => "ajwf:DependencyParentJob:parent-123",
        "run_id" => run_id,
        "state" => "running"
      },
      result.first
    )
  end

  it "describes an explicit workflow run when a run ID is provided" do
    stub_workflow_handle(
      "ajwf:DependencyParentJob:parent-123",
      run_id: run_id,
      description: workflow_description(
        workflow_id: "ajwf:DependencyParentJob:parent-123",
        run_id: run_id,
        status: Temporalio::Client::WorkflowExecutionStatus::RUNNING
      )
    )

    result = activity.execute([
                                {
                                  "workflow_id" => "ajwf:DependencyParentJob:parent-123",
                                  "run_id" => run_id
                                }
                              ])

    assert_hash_includes(
      {
        "workflow_id" => "ajwf:DependencyParentJob:parent-123",
        "run_id" => run_id,
        "state" => "running"
      },
      result.first
    )
  end

  it "follows an exact run that continued as new to the latest workflow run" do
    stub_workflow_handle(
      "ajwf:DependencyParentJob:parent-123",
      run_id: "run-1",
      description: workflow_description(
        workflow_id: "ajwf:DependencyParentJob:parent-123",
        run_id: "run-1",
        status: Temporalio::Client::WorkflowExecutionStatus::CONTINUED_AS_NEW
      )
    )
    stub_workflow_handle(
      "ajwf:DependencyParentJob:parent-123",
      description: workflow_description(
        workflow_id: "ajwf:DependencyParentJob:parent-123",
        run_id: "run-2",
        status: Temporalio::Client::WorkflowExecutionStatus::RUNNING
      )
    )

    result = activity.execute([
                                {
                                  "workflow_id" => "ajwf:DependencyParentJob:parent-123",
                                  "run_id" => "run-1"
                                }
                              ])

    assert_hash_includes(
      {
        "workflow_id" => "ajwf:DependencyParentJob:parent-123",
        "run_id" => "run-2",
        "state" => "running"
      },
      result.first
    )
  end

  it "falls back to the default workflow ID for class-qualified dependencies" do
    stub_list_workflows(
      "ajClass='DependencyParentJob' AND ajJobId='parent-123' ORDER BY StartTime DESC",
      []
    )
    stub_workflow_handle(
      "ajwf:DependencyParentJob:parent-123",
      description: workflow_description(
        workflow_id: "ajwf:DependencyParentJob:parent-123",
        status: Temporalio::Client::WorkflowExecutionStatus::FAILED
      )
    )

    result = activity.execute([{ "job_class" => "DependencyParentJob", "job_id" => "parent-123" }])

    assert_hash_includes(
      {
        "job_class" => "DependencyParentJob",
        "job_id" => "parent-123",
        "workflow_id" => "ajwf:DependencyParentJob:parent-123",
        "state" => "failed"
      },
      result.first
    )
  end

  it "returns not_found when no workflow can be resolved" do
    stub_list_workflows("ajJobId='missing-parent' ORDER BY StartTime DESC", [])

    result = activity.execute([{ "job_id" => "missing-parent" }])

    assert_equal [
      {
        "job_id" => "missing-parent",
        "state" => "not_found"
      }
    ], result
  end

  it "returns not_found when Temporal reports a missing workflow" do
    stub_workflow_handle(
      "ajwf:DependencyParentJob:parent-123",
      error: not_found_error
    )

    result = activity.execute([{ "workflow_id" => "ajwf:DependencyParentJob:parent-123" }])

    assert_hash_includes(
      {
        "workflow_id" => "ajwf:DependencyParentJob:parent-123",
        "state" => "not_found"
      },
      result.first
    )
  end

  it "falls back to search attributes when a default workflow ID misses" do
    stub_workflow_handle(
      "ajwf:DependencyParentJob:parent-123",
      error: not_found_error
    )
    stub_list_workflows(
      "ajClass='DependencyParentJob' AND ajJobId='parent-123' ORDER BY StartTime DESC",
      [workflow("custom:parent-123")]
    )
    stub_workflow_handle(
      "custom:parent-123",
      run_id: run_id,
      description: workflow_description(
        workflow_id: "custom:parent-123",
        status: Temporalio::Client::WorkflowExecutionStatus::COMPLETED
      )
    )

    result = activity.execute([
                                {
                                  "job_class" => "DependencyParentJob",
                                  "job_id" => "parent-123",
                                  "workflow_id" => "ajwf:DependencyParentJob:parent-123"
                                }
                              ])

    assert_hash_includes(
      {
        "workflow_id" => "custom:parent-123",
        "state" => "completed"
      },
      result.first
    )
  end

  def workflow_description(workflow_id:, status:, run_id: self.run_id)
    DependencyStatusActivitySpecSupport::Description.new(id: workflow_id, run_id: run_id, status: status)
  end

  def workflow(workflow_id)
    DependencyStatusActivitySpecSupport::Workflow.new(id: workflow_id, run_id: run_id)
  end

  def stub_workflow_handle(workflow_id, run_id: nil, description: nil, error: nil)
    client.stub_workflow_handle(
      workflow_id,
      run_id: run_id,
      handle: DependencyStatusActivitySpecSupport::Handle.new(description: description, error: error)
    )
  end

  def stub_list_workflows(query, result)
    client.stub_list_workflows(query, result)
  end

  def invalid_argument_error
    Temporalio::Error::RPCError.new(
      "invalid query",
      code: Temporalio::Error::RPCError::Code::INVALID_ARGUMENT,
      raw_grpc_status: nil
    )
  end

  def not_found_error
    Temporalio::Error::RPCError.new(
      "not found",
      code: Temporalio::Error::RPCError::Code::NOT_FOUND,
      raw_grpc_status: nil
    )
  end
end
