# frozen_string_literal: true

require "spec_helper"

module StuckJobsSpecSupport
  class FakeClient
    attr_accessor :workflows, :count, :capabilities
    attr_reader :namespace_requests, :list_queries, :count_queries

    def initialize
      @workflows = []
      @capabilities = { reported_problems_search_attribute: true }
      @namespace_requests = []
      @list_queries = []
      @count_queries = []
    end

    def namespace
      "job-namespace"
    end

    def workflow_service
      self
    end

    def describe_namespace(request)
      @namespace_requests << request.namespace
      Temporalio::Api::WorkflowService::V1::DescribeNamespaceResponse.new(
        namespace_info: { capabilities: capabilities }
      )
    end

    def list_workflows(query)
      @list_queries << query
      workflows
    end

    def count_workflows(query)
      @count_queries << query
      Temporalio::Client::WorkflowExecutionCount.new(count, [])
    end
  end
end

describe "Stuck job detection" do
  let(:stuck_jobs) { ActiveJob::Temporal::StuckJobs }
  let(:client) { StuckJobsSpecSupport::FakeClient.new }
  let(:query) do
    "ExecutionStatus='Running' AND WorkflowType IN ('AjWorkflow', 'ActiveJobTemporalDeadLetterWorkflow') AND " \
      "TemporalReportedProblems IN ('category=WorkflowTaskFailed', 'category=WorkflowTaskTimedOut')"
  end

  it "lists running job workflows with reported workflow task problems" do
    assert_empty stuck_jobs.list(client: client)
    assert_equal [query], client.list_queries
    assert_equal ["job-namespace"], client.namespace_requests
  end

  it "filters by the job class and ActiveJob queue" do
    job_class = stub_const("StuckJobSpecJob", Class.new)

    stuck_jobs.list(job_class: job_class, queue: "billing", client: client)

    assert_equal ["#{query} AND ajClass='StuckJobSpecJob' AND ajQueue='billing'"], client.list_queries
  end

  it "maps execution details and stops enumerating at the limit" do
    problems = ["category=WorkflowTaskFailed", "cause=NonDeterministicError"]
    started_at = Time.utc(2026, 11, 18)
    attributes = {
      "ajClass" => "BillingJob", "ajJobId" => "job-1", "ajQueue" => "billing", "TemporalReportedProblems" => problems,
      "ajEnqueuedAt" => started_at.iso8601
    }
    workflow = workflow_execution(attributes, started_at: started_at)
    client.workflows = Enumerator.new do |results|
      results << workflow
      raise "enumerated past the limit"
    end

    assert_equal(
      [{ workflow_id: "workflow-1", run_id: "run-1", workflow_type: "AjWorkflow", job_class: "BillingJob",
         job_id: "job-1", queue: "billing", started_at: started_at, problems: problems }],
      stuck_jobs.list(limit: 1, client: client)
    )
  end

  it "returns nil job metadata when the workflow has no ActiveJob search attributes" do
    problems = ["category=WorkflowTaskTimedOut", "cause=ScheduleToClose"]
    client.workflows = [workflow_execution({ "TemporalReportedProblems" => problems })]

    assert_equal [nil, nil, nil, problems], stuck_jobs.list(client: client).first.values_at(
      :job_class, :job_id, :queue, :problems
    )
  end

  it "rejects limits that are not positive integers" do
    [0, -1, 1.5, "1"].each do |limit|
      assert_raises(ArgumentError) { stuck_jobs.list(limit: limit, client: client) }
    end
    assert_empty client.list_queries
  end

  it "rejects unsafe query values" do
    [{ job_class: "Job'Name" }, { queue: "mail\\queue" }].each do |filters|
      assert_raises(ArgumentError) { stuck_jobs.list(**filters, client: client) }
    end
    assert_empty client.list_queries
  end

  it "checks capability on every call and skips visibility queries when it is disabled or missing" do
    stuck_jobs.list(client: client)
    client.capabilities = { reported_problems_search_attribute: false }

    error = assert_raises(ActiveJob::Temporal::Error) { stuck_jobs.list(client: client) }
    assert_includes error.message, "Temporal server >= 1.30"
    assert_includes error.message, "system.numConsecutiveWorkflowTaskProblemsToTriggerSearchAttribute > 0"

    client.capabilities = nil
    assert_raises(ActiveJob::Temporal::Error) { stuck_jobs.count(client: client) }
    assert_equal [query], client.list_queries
    assert_empty client.count_queries
    assert_equal ["job-namespace"] * 3, client.namespace_requests
  end

  it "wraps an invalid argument from lazy enumeration and preserves the RPC error" do
    error = rpc_error(:INVALID_ARGUMENT)
    client.workflows = Enumerator.new { raise error }

    wrapped = assert_raises(ActiveJob::Temporal::Error) { stuck_jobs.list(client: client) }

    assert_same error, wrapped.cause
    assert_includes wrapped.message, "stuck job query rejected by Temporal"
  end

  it "passes other RPC errors through from lazy enumeration" do
    error = rpc_error(:UNAVAILABLE)
    client.workflows = Enumerator.new { raise error }

    assert_same error, assert_raises(Temporalio::Error::RPCError) { stuck_jobs.list(client: client) }
  end

  it "returns the server count for the filtered visibility query" do
    client.count = 175

    assert_equal 175, stuck_jobs.count(job_class: "BillingJob", queue: "billing", client: client)
    assert_equal ["#{query} AND ajClass='BillingJob' AND ajQueue='billing'"], client.count_queries
    assert_equal ["job-namespace"], client.namespace_requests
  end

  private

  def workflow_execution(values, started_at: Time.utc(2026, 11, 18))
    converter = Temporalio::Converters::PayloadConverter.default
    fields = values.transform_values { |value| converter.to_payload(value) }
    fields.each do |name, payload|
      payload.metadata["type"] = {
        "ajEnqueuedAt" => "Datetime", "TemporalReportedProblems" => "KeywordList"
      }.fetch(name, "Keyword")
    end
    info = Temporalio::Api::Workflow::V1::WorkflowExecutionInfo.new(
      execution: { workflow_id: "workflow-1", run_id: "run-1" },
      type: { name: "AjWorkflow" },
      start_time: { seconds: started_at.to_i },
      search_attributes: { indexed_fields: fields }
    )
    Temporalio::Client::WorkflowExecution.new(info, Temporalio::Converters::DataConverter.default)
  end

  def rpc_error(code)
    status = Temporalio::Error::RPCError::Code.const_get(code)
    Temporalio::Error::RPCError.new("visibility query failed", code: status, raw_grpc_status: nil)
  end
end
