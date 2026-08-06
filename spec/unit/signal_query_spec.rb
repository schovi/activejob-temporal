# frozen_string_literal: true

require "spec_helper"

module SignalQuerySpecSupport
  WorkflowExecution = Struct.new(:id, :run_id)

  class RecordingClient
    attr_reader :calls

    def initialize
      @calls = MinitestHelpers::CallRecorder.new
      @workflow_handles = {}
      @workflow_lists = {}
    end

    def register_workflow_handle(workflow_id, run_id:, handle:)
      @workflow_handles[[workflow_id, run_id]] = handle
    end

    def register_workflows(query, workflows)
      @workflow_lists[query] = workflows
    end

    def workflow_handle(workflow_id, run_id: nil)
      calls.record(:workflow_handle, workflow_id, run_id: run_id)
      @workflow_handles.fetch([workflow_id, run_id])
    end

    def list_workflows(query)
      calls.record(:list_workflows, query)
      @workflow_lists.fetch(query, [])
    end
  end

  class RecordingHandle
    attr_reader :calls

    def initialize
      @calls = MinitestHelpers::CallRecorder.new
      @responses = {}
      @errors = {}
    end

    def returns(method_name, value)
      @responses[method_name] = value
    end

    def raises(method_name, error)
      @errors[method_name] = error
    end

    def signal(name, *, **)
      record_and_return(:signal, name, *, **)
    end

    def query(name, *, **)
      record_and_return(:query, name, *, **)
    end

    def execute_update(name, *, **)
      record_and_return(:execute_update, name, *, **)
    end

    private

    def record_and_return(method_name, *, **)
      calls.record(method_name, *, **)
      raise @errors[method_name] if @errors.key?(method_name)

      @responses[method_name]
    end
  end
end

describe ActiveJob::Temporal::SignalQuery do
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "SignalQueryJob"
    end
  end
  let(:job_id) { "550e8400-e29b-41d4-a716-446655440000" }
  let(:default_workflow_id) { "ajwf:#{job_class.name}:#{job_id}" }
  let(:custom_workflow_id) { "tenant:42:#{default_workflow_id}" }
  let(:run_id) { "run-1" }
  let(:search_query) do
    "ajClass='#{job_class.name}' AND ajJobId='#{job_id}' AND ExecutionStatus='Running'"
  end
  let(:client) { SignalQuerySpecSupport::RecordingClient.new }
  let(:default_handle) { SignalQuerySpecSupport::RecordingHandle.new }
  let(:custom_handle) { SignalQuerySpecSupport::RecordingHandle.new }
  let(:workflow_execution) { SignalQuerySpecSupport::WorkflowExecution.new(custom_workflow_id, run_id) }
  let(:not_found_error) do
    Temporalio::Error::RPCError.new(
      "not found",
      code: Temporalio::Error::RPCError::Code::NOT_FOUND,
      raw_grpc_status: nil
    )
  end

  before do
    call_recorded_method(ActiveJob::Temporal, :client, returns: client)
    client.register_workflow_handle(default_workflow_id, run_id: nil, handle: default_handle)
    client.register_workflow_handle(custom_workflow_id, run_id: run_id, handle: custom_handle)
    client.register_workflows(search_query, [workflow_execution])
    default_handle.returns(:query, "default-result")
    default_handle.returns(:execute_update, "default-update-result")
    custom_handle.returns(:query, "custom-result")
    custom_handle.returns(:execute_update, "custom-update-result")
  end

  describe ".signal" do
    it "sends signals to the default workflow handle before searching" do
      described_class.signal(job_class, job_id, :pause, "manual hold")

      assert_called_with(default_handle.calls, :signal, "pause", "manual hold")
      refute_called(client.calls, :list_workflows)
    end

    it "falls back to the running workflow found by job search attributes" do
      default_handle.raises(:signal, not_found_error)

      described_class.signal(job_class, job_id, :pause, "manual hold")

      assert_called_with(client.calls, :list_workflows, search_query)
      assert_called_with(custom_handle.calls, :signal, "pause", "manual hold")
    end

    it "refuses to search fallback workflows for unsafe job class names" do
      dynamic_job_class = Class.new(ActiveJob::Base)
      safe_name = "SignalQueryJob"
      unsafe_name = "SignalQueryJob' OR '1'='1"
      name_sequence = [safe_name, safe_name, safe_name, unsafe_name]

      dynamic_job_class.define_singleton_method(:name) { name_sequence.shift || unsafe_name }
      client.register_workflow_handle("ajwf:#{safe_name}:#{job_id}", run_id: nil, handle: default_handle)
      default_handle.raises(:signal, not_found_error)

      assert_raises(ArgumentError) { described_class.signal(dynamic_job_class, job_id, :pause) }
      refute_called(client.calls, :list_workflows)
    end

    it "refuses to search fallback workflows for unsafe job IDs" do
      custom_job_id = "tenant'42:invoice-123"
      custom_default_workflow_id = "ajwf:#{job_class.name}:#{custom_job_id}"

      client.register_workflow_handle(custom_default_workflow_id, run_id: nil, handle: default_handle)
      default_handle.raises(:signal, not_found_error)

      assert_raises(ArgumentError) { described_class.signal(job_class, custom_job_id, :pause) }
      refute_called(client.calls, :list_workflows)
    end

    it "raises WorkflowNotFoundError when no running workflow is found" do
      default_handle.raises(:signal, not_found_error)
      client.register_workflows(search_query, [])

      error = assert_raises(ActiveJob::Temporal::WorkflowNotFoundError) do
        described_class.signal(job_class, job_id, :pause)
      end

      assert_match(/No running workflow/, error.message)
    end

    it "does not wrap non-RPC default handle failures as connection errors" do
      signal_error = RuntimeError.new("signal handler failed")

      default_handle.raises(:signal, signal_error)

      error = assert_raises(RuntimeError) { described_class.signal(job_class, job_id, :pause) }

      assert_same signal_error, error
      refute_called(client.calls, :list_workflows)
    end

    it "validates arguments before contacting Temporal" do
      error = assert_raises(ArgumentError) { described_class.signal(job_class, "bad\nid", :pause) }
      assert_match(/control characters/, error.message)

      error = assert_raises(ArgumentError) { described_class.signal("SignalQueryJob", job_id, :pause) }
      assert_match(/job_class must be a named class/, error.message)

      error = assert_raises(ArgumentError) { described_class.signal(job_class, job_id, "invalid-name") }
      assert_match(/signal names/, error.message)

      refute_called(client.calls, :workflow_handle)
    end
  end

  describe ".query" do
    it "queries the default workflow handle before searching" do
      result = described_class.query(job_class, job_id, :state)

      assert_equal "default-result", result
      assert_called_with(default_handle.calls, :query, "state")
      refute_called(client.calls, :list_workflows)
    end

    it "falls back to the running workflow found by job search attributes" do
      default_handle.raises(:query, not_found_error)

      result = described_class.query(job_class, job_id, :state)

      assert_equal "custom-result", result
      assert_called_with(client.calls, :list_workflows, search_query)
      assert_called_with(custom_handle.calls, :query, "state")
    end

    it "queries custom non-UUID job IDs" do
      custom_job_id = "invoice-123"
      custom_default_workflow_id = "ajwf:#{job_class.name}:#{custom_job_id}"

      client.register_workflow_handle(custom_default_workflow_id, run_id: nil, handle: default_handle)

      result = described_class.query(job_class, custom_job_id, :state)

      assert_equal "default-result", result
      assert_called_with(default_handle.calls, :query, "state")
      refute_called(client.calls, :list_workflows)
    end

    it "forwards an explicit query reject condition" do
      described_class.query(job_class, job_id, :state, reject_condition: :not_open)

      assert_called_with(default_handle.calls, :query, "state", reject_condition: :not_open)
    end

    it "raises workflow query failures without wrapping them as connection errors" do
      query_error = Temporalio::Error::WorkflowQueryFailedError.new("query failed")

      default_handle.raises(:query, query_error)

      error = assert_raises(Temporalio::Error::WorkflowQueryFailedError) do
        described_class.query(job_class, job_id, :state)
      end

      assert_same query_error, error
    end

    it "does not wrap non-RPC default handle failures as connection errors" do
      query_error = RuntimeError.new("query handler failed")

      default_handle.raises(:query, query_error)

      error = assert_raises(RuntimeError) { described_class.query(job_class, job_id, :state) }

      assert_same query_error, error
      refute_called(client.calls, :list_workflows)
    end

    it "raises WorkflowNotFoundError when no running workflow is found" do
      default_handle.raises(:query, not_found_error)
      client.register_workflows(search_query, [])

      error = assert_raises(ActiveJob::Temporal::WorkflowNotFoundError) do
        described_class.query(job_class, job_id, :state)
      end

      assert_match(/No running workflow/, error.message)
    end

    it "validates job IDs before contacting Temporal" do
      error = assert_raises(ArgumentError) { described_class.query(job_class, "bad\nid", :state) }

      assert_match(/control characters/, error.message)
      refute_called(client.calls, :workflow_handle)
    end
  end

  describe ".update" do
    it "executes updates on the default workflow handle before searching" do
      result = described_class.update(job_class, job_id, :set_progress, 75)

      assert_equal "default-update-result", result
      assert_called_with(default_handle.calls, :execute_update, "set_progress", 75)
      refute_called(client.calls, :list_workflows)
    end

    it "falls back to the running workflow found by job search attributes" do
      default_handle.raises(:execute_update, not_found_error)

      result = described_class.update(job_class, job_id, :set_progress, 75)

      assert_equal "custom-update-result", result
      assert_called_with(client.calls, :list_workflows, search_query)
      assert_called_with(custom_handle.calls, :execute_update, "set_progress", 75)
    end

    it "updates custom non-UUID job IDs" do
      custom_job_id = "invoice-123"
      custom_default_workflow_id = "ajwf:#{job_class.name}:#{custom_job_id}"

      client.register_workflow_handle(custom_default_workflow_id, run_id: nil, handle: default_handle)

      result = described_class.update(job_class, custom_job_id, :set_progress, 75)

      assert_equal "default-update-result", result
      assert_called_with(default_handle.calls, :execute_update, "set_progress", 75)
      refute_called(client.calls, :list_workflows)
    end

    it "updates schedule-style job IDs" do
      schedule_job_id = "ajschwf:daily-report-2026-05-25T20:07:45Z:019e60c0-2587-710d-8633-a0f90e9dd6f9"
      schedule_workflow_id = "ajschwf:daily-report-2026-05-25T20:07:45Z"
      schedule_run_id = "019e60c0-2587-710d-8633-a0f90e9dd6f9"

      client.register_workflow_handle(schedule_workflow_id, run_id: schedule_run_id, handle: default_handle)

      result = described_class.update(job_class, schedule_job_id, :set_progress, 75)

      assert_equal "default-update-result", result
      assert_called_with(default_handle.calls, :execute_update, "set_progress", 75)
      assert_called_with(client.calls, :workflow_handle, schedule_workflow_id, run_id: schedule_run_id)
      refute_called(client.calls, :list_workflows)
    end

    it "raises workflow update failures without wrapping them as connection errors" do
      update_error = Temporalio::Error::WorkflowUpdateFailedError.new

      default_handle.raises(:execute_update, update_error)

      error = assert_raises(Temporalio::Error::WorkflowUpdateFailedError) do
        described_class.update(job_class, job_id, :set_progress, 75)
      end

      assert_same update_error, error
    end

    it "raises WorkflowNotFoundError when no running workflow is found" do
      default_handle.raises(:execute_update, not_found_error)
      client.register_workflows(search_query, [])

      error = assert_raises(ActiveJob::Temporal::WorkflowNotFoundError) do
        described_class.update(job_class, job_id, :set_progress, 75)
      end

      assert_match(/No running workflow/, error.message)
    end

    it "validates arguments before contacting Temporal" do
      error = assert_raises(ArgumentError) { described_class.update(job_class, "bad\nid", :set_progress) }
      assert_match(/control characters/, error.message)

      error = assert_raises(ArgumentError) { described_class.update("SignalQueryJob", job_id, :set_progress) }
      assert_match(/job_class must be a named class/, error.message)

      error = assert_raises(ArgumentError) { described_class.update(job_class, job_id, "invalid-name") }
      assert_match(/update names/, error.message)

      refute_called(client.calls, :workflow_handle)
    end
  end
end

describe ActiveJob::Temporal do
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "SignalQueryDelegationJob"
    end
  end
  let(:job_id) { "550e8400-e29b-41d4-a716-446655440000" }

  describe ".signal" do
    it "delegates to SignalQuery" do
      signal_calls = call_recorded_method(ActiveJob::Temporal::SignalQuery, :signal)

      described_class.signal(job_class, job_id, :pause, "manual hold")

      assert_called_with(signal_calls, :signal, job_class, job_id, :pause, "manual hold")
    end
  end

  describe ".query" do
    it "delegates to SignalQuery" do
      query_calls = call_recorded_method(ActiveJob::Temporal::SignalQuery, :query, returns: "paused")

      assert_equal "paused", described_class.query(job_class, job_id, :state)
      assert_called_with(
        query_calls,
        :query,
        job_class,
        job_id,
        :state,
        reject_condition: ActiveJob::Temporal::SignalQuery::DEFAULT_REJECT_CONDITION
      )
    end
  end

  describe ".update" do
    it "delegates to SignalQuery" do
      update_calls = call_recorded_method(ActiveJob::Temporal::SignalQuery, :update, returns: "updated")

      assert_equal "updated", described_class.update(job_class, job_id, :set_progress, 75)
      assert_called_with(update_calls, :update, job_class, job_id, :set_progress, 75)
    end
  end
end
