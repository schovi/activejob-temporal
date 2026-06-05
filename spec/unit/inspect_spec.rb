# frozen_string_literal: true

require "spec_helper"
require_relative "../fixtures/sample_jobs"

module InspectSpecSupport
  WorkflowExecution = Struct.new(:id, :run_id, keyword_init: true)
  RawDescription = Struct.new(:pending_activities, keyword_init: true)
  ApplicationFailureInfo = Struct.new(:type, keyword_init: true)
  Failure = Struct.new(:application_failure_info, :message, keyword_init: true)
  PendingActivity = Struct.new(:attempt, :last_failure, keyword_init: true)

  WorkflowDescription = Struct.new(
    :id,
    :run_id,
    :status,
    :start_time,
    :close_time,
    :raw_description,
    keyword_init: true
  )

  class FakeClient
    attr_reader :workflow_handle_calls, :list_workflows_calls

    def initialize
      @workflow_handles = {}
      @list_workflows_results = {}
      @list_workflows_errors = {}
      @workflow_handle_calls = []
      @list_workflows_calls = []
    end

    def handle_for(workflow_id, run_id:, handle:)
      @workflow_handles[[workflow_id, run_id]] = handle
    end

    def list_workflows_for(query, result)
      @list_workflows_results[query] = result
    end

    def raise_on_list_workflows(query, error)
      @list_workflows_errors[query] = error
    end

    def workflow_handle(workflow_id, run_id: nil)
      @workflow_handle_calls << [workflow_id, run_id]
      @workflow_handles.fetch([workflow_id, run_id])
    end

    def list_workflows(query)
      @list_workflows_calls << query
      raise @list_workflows_errors.fetch(query) if @list_workflows_errors.key?(query)

      @list_workflows_results.fetch(query, [])
    end
  end

  class FakeWorkflowHandle
    attr_accessor :description, :describe_error
    attr_reader :describe_calls

    def initialize(description:)
      @description = description
      @describe_calls = 0
    end

    def describe
      @describe_calls += 1
      raise describe_error if describe_error

      description
    end
  end
end

describe ActiveJob::Temporal::Inspect do
  let(:job_class) { SimpleJob }
  let(:job_id) { "550e8400-e29b-41d4-a716-446655440000" }
  let(:workflow_id) { "ajwf:#{job_class.name}:#{job_id}" }
  let(:run_id) { "run-1" }
  let(:query) { "ajClass='#{job_class.name}' AND ajJobId='#{job_id}'" }
  let(:started_at) { Time.utc(2026, 5, 20, 13, 0, 0) }
  let(:client) { InspectSpecSupport::FakeClient.new }
  let(:handle) { InspectSpecSupport::FakeWorkflowHandle.new(description: description) }
  let(:workflow_execution) { InspectSpecSupport::WorkflowExecution.new(id: workflow_id, run_id: run_id) }
  let(:raw_description) { InspectSpecSupport::RawDescription.new(pending_activities: []) }
  let(:description) do
    InspectSpecSupport::WorkflowDescription.new(
      id: workflow_id,
      run_id: run_id,
      status: Temporalio::Client::WorkflowExecutionStatus::RUNNING,
      start_time: started_at,
      close_time: nil,
      raw_description: raw_description
    )
  end
  let(:not_found_error) do
    Temporalio::Error::RPCError.new(
      "not found",
      code: Temporalio::Error::RPCError::Code::NOT_FOUND,
      raw_grpc_status: nil
    )
  end

  before do
    call_recorded_method(ActiveJob::Temporal, :client, returns: client)
    client.list_workflows_for(query, [workflow_execution])
    client.handle_for(workflow_id, run_id: nil, handle: handle)
  end

  describe ".status" do
    it "returns workflow status from Temporal describe" do
      result = described_class.status(job_class, job_id)

      assert_equal(
        {
          state: :running,
          workflow_id: workflow_id,
          run_id: run_id,
          started_at: started_at,
          closed_at: nil,
          attempt: nil,
          last_failure: nil
        },
        result
      )
    end

    it "uses the workflow ID discovered by search attributes" do
      custom_workflow_id = "tenant-42:ajwf:#{job_class.name}:#{job_id}"
      custom_execution = InspectSpecSupport::WorkflowExecution.new(id: custom_workflow_id, run_id: run_id)
      custom_handle = InspectSpecSupport::FakeWorkflowHandle.new(description: description)

      handle.describe_error = not_found_error
      client.list_workflows_for(query, [custom_execution])
      client.handle_for(custom_workflow_id, run_id: run_id, handle: custom_handle)

      described_class.status(job_class, job_id)

      assert_includes client.workflow_handle_calls, [custom_workflow_id, run_id]
    end

    it "escapes job class names when searching fallback workflows" do
      dynamic_job_class = Class.new(ActiveJob::Base)
      safe_name = "SimpleJob"
      unsafe_name = "SimpleJob' OR '1'='1"
      names = [safe_name, safe_name, safe_name, unsafe_name]
      escaped_query = "ajClass='SimpleJob'' OR ''1''=''1' AND ajJobId='#{job_id}'"
      custom_workflow_id = "tenant-42:ajwf:#{safe_name}:#{job_id}"
      custom_execution = InspectSpecSupport::WorkflowExecution.new(id: custom_workflow_id, run_id: run_id)
      custom_handle = InspectSpecSupport::FakeWorkflowHandle.new(description: description)

      handle.describe_error = not_found_error
      client.handle_for("ajwf:#{safe_name}:#{job_id}", run_id: nil, handle: handle)
      client.list_workflows_for(escaped_query, [custom_execution])
      client.handle_for(custom_workflow_id, run_id: run_id, handle: custom_handle)

      call_recorded_method(dynamic_job_class, :name) { names.shift }

      described_class.status(dynamic_job_class, job_id)

      assert_includes client.list_workflows_calls, escaped_query
    end

    it "escapes custom job IDs when searching fallback workflows" do
      custom_job_id = "tenant'42:invoice-123"
      custom_query = "ajClass='#{job_class.name}' AND ajJobId='tenant''42:invoice-123'"
      custom_workflow_id = "tenant-42:ajwf:#{job_class.name}:#{custom_job_id}"
      custom_execution = InspectSpecSupport::WorkflowExecution.new(id: custom_workflow_id, run_id: run_id)
      custom_handle = InspectSpecSupport::FakeWorkflowHandle.new(description: description)

      handle.describe_error = not_found_error
      client.handle_for("ajwf:#{job_class.name}:#{custom_job_id}", run_id: nil, handle: handle)
      client.list_workflows_for(custom_query, [custom_execution])
      client.handle_for(custom_workflow_id, run_id: run_id, handle: custom_handle)

      described_class.status(job_class, custom_job_id)

      assert_includes client.list_workflows_calls, custom_query
      assert_includes client.workflow_handle_calls, [custom_workflow_id, run_id]
    end

    it "inspects schedule-style job IDs" do
      schedule_job_id = "ajschwf:daily-report-2026-05-25T20:07:45Z:019e60c0-2587-710d-8633-a0f90e9dd6f9"
      schedule_workflow_id = "ajschwf:daily-report-2026-05-25T20:07:45Z"
      schedule_run_id = "019e60c0-2587-710d-8633-a0f90e9dd6f9"

      client.handle_for(schedule_workflow_id, run_id: schedule_run_id, handle: handle)

      result = described_class.status(job_class, schedule_job_id)

      assert_equal :running, result[:state]
      assert_includes client.workflow_handle_calls, [schedule_workflow_id, schedule_run_id]
      assert_empty client.list_workflows_calls
    end

    it "uses the default workflow ID before querying search attributes" do
      result = described_class.status(job_class, job_id)

      assert_equal workflow_id, result[:workflow_id]
      assert_includes client.workflow_handle_calls, [workflow_id, nil]
      assert_empty client.list_workflows_calls
    end

    it "returns nil when the workflow does not exist" do
      handle.describe_error = not_found_error
      client.list_workflows_for(query, [])

      assert_nil described_class.status(job_class, job_id)
    end

    it "returns nil when search attributes are unavailable and the default workflow ID is missing" do
      invalid_argument_error = Temporalio::Error::RPCError.new(
        "invalid search attribute",
        code: Temporalio::Error::RPCError::Code::INVALID_ARGUMENT,
        raw_grpc_status: nil
      )

      handle.describe_error = not_found_error
      client.raise_on_list_workflows(query, invalid_argument_error)

      assert_nil described_class.status(job_class, job_id)
    end

    it "maps completed workflow status" do
      handle.description = workflow_description(
        status: Temporalio::Client::WorkflowExecutionStatus::COMPLETED,
        close_time: Time.utc(2026, 5, 20, 13, 1, 0)
      )

      assert_equal :completed, described_class.status(job_class, job_id)[:state]
    end

    it "includes pending activity attempt and failure details when available" do
      failure_info = InspectSpecSupport::ApplicationFailureInfo.new(type: "NetworkError")
      failure = InspectSpecSupport::Failure.new(application_failure_info: failure_info, message: "timeout")
      pending_activity = InspectSpecSupport::PendingActivity.new(attempt: 2, last_failure: failure)

      description.raw_description = InspectSpecSupport::RawDescription.new(pending_activities: [pending_activity])

      result = described_class.status(job_class, job_id)

      assert_equal 2, result[:attempt]
      assert_equal "NetworkError: timeout", result[:last_failure]
    end

    it "raises ArgumentError for unsafe job IDs before querying Temporal" do
      error = assert_raises(ArgumentError) { described_class.status(job_class, "bad\nid") }

      assert_match(/control characters/, error.message)
      assert_empty client.list_workflows_calls
    end

    it "raises ArgumentError for blank job IDs before querying Temporal" do
      error = assert_raises(ArgumentError) { described_class.status(job_class, " ") }

      assert_match(/job_id must not be blank/, error.message)
      assert_empty client.list_workflows_calls
    end

    it "raises ArgumentError for non-class job_class values before querying Temporal" do
      fake_class = Struct.new(:name).new("FakeJob")

      error = assert_raises(ArgumentError) { described_class.status(fake_class, job_id) }

      assert_match(/job_class must be a named class/, error.message)
      assert_empty client.list_workflows_calls
    end

    it "raises ArgumentError for unsafe job class names before querying Temporal" do
      unsafe_class = Class.new

      call_recorded_method(unsafe_class, :name, returns: "Unsafe'Job")

      error = assert_raises(ArgumentError) { described_class.status(unsafe_class, job_id) }

      assert_match(/valid constant name/, error.message)
      assert_empty client.list_workflows_calls
    end

    it "wraps Temporal connection failures" do
      handle.describe_error = StandardError.new("connection refused")

      error = assert_raises(ActiveJob::Temporal::TemporalConnectionError) do
        described_class.status(job_class, job_id)
      end

      assert_match(/Failed to inspect Temporal workflow/, error.message)
    end
  end

  describe "predicate methods" do
    it "reports running workflows" do
      assert described_class.running?(job_class, job_id)
      refute described_class.completed?(job_class, job_id)
      refute described_class.failed?(job_class, job_id)
    end

    it "reports completed workflows" do
      handle.description = workflow_description(status: Temporalio::Client::WorkflowExecutionStatus::COMPLETED)

      refute described_class.running?(job_class, job_id)
      assert described_class.completed?(job_class, job_id)
      refute described_class.failed?(job_class, job_id)
    end

    it "returns false when the workflow is missing" do
      handle.describe_error = not_found_error
      client.list_workflows_for(query, [])

      refute described_class.running?(job_class, job_id)
      refute described_class.completed?(job_class, job_id)
      refute described_class.failed?(job_class, job_id)
    end
  end

  private

  def workflow_description(status:, close_time: nil)
    InspectSpecSupport::WorkflowDescription.new(
      id: workflow_id,
      run_id: run_id,
      status: status,
      start_time: started_at,
      close_time: close_time,
      raw_description: raw_description
    )
  end
end

describe ActiveJob::Temporal do
  let(:job_id) { "550e8400-e29b-41d4-a716-446655440000" }

  describe ".status" do
    it "delegates to the inspection module" do
      status = { state: :running }
      recorder = call_recorded_method(ActiveJob::Temporal::Inspect, :status, returns: status)

      assert_equal status, described_class.status(SimpleJob, job_id)
      assert_called_with recorder, :status, SimpleJob, job_id
    end
  end

  describe ".running?" do
    it "delegates to the inspection module" do
      recorder = call_recorded_method(ActiveJob::Temporal::Inspect, :running?, returns: true)

      assert described_class.running?(SimpleJob, job_id)
      assert_called_with recorder, :running?, SimpleJob, job_id
    end
  end

  describe ".completed?" do
    it "delegates to the inspection module" do
      recorder = call_recorded_method(ActiveJob::Temporal::Inspect, :completed?, returns: true)

      assert described_class.completed?(SimpleJob, job_id)
      assert_called_with recorder, :completed?, SimpleJob, job_id
    end
  end

  describe ".failed?" do
    it "delegates to the inspection module" do
      recorder = call_recorded_method(ActiveJob::Temporal::Inspect, :failed?, returns: true)

      assert described_class.failed?(SimpleJob, job_id)
      assert_called_with recorder, :failed?, SimpleJob, job_id
    end
  end
end
