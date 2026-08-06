# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/dead_letter_queue"

module DeadLetterQueueSpecSupport
  WorkflowExecution = Struct.new(:id, :run_id, keyword_init: true)

  class FakeClient
    attr_accessor :start_workflow_result, :start_workflow_error
    attr_reader :workflow_handle_calls, :list_workflows_calls, :start_workflow_calls

    def initialize
      @workflow_handles = {}
      @list_workflows_results = {}
      @workflow_handle_calls = []
      @list_workflows_calls = []
      @start_workflow_calls = []
    end

    def handle_for(workflow_id, handle:, run_id: nil)
      @workflow_handles[[workflow_id, run_id]] = handle
    end

    def list_workflows_for(query, result)
      @list_workflows_results[query] = result
    end

    def workflow_handle(workflow_id, run_id: nil)
      @workflow_handle_calls << [workflow_id, run_id]
      @workflow_handles.fetch([workflow_id, run_id])
    end

    def list_workflows(query)
      @list_workflows_calls << query
      @list_workflows_results.fetch(query)
    end

    def start_workflow(*arguments, **keywords)
      @start_workflow_calls << { arguments: arguments, keywords: keywords }
      raise start_workflow_error if start_workflow_error

      start_workflow_result
    end
  end

  class FakeWorkflowHandle
    attr_accessor :query_error, :signal_error
    attr_reader :query_calls, :signal_calls

    def initialize(query_results: [])
      @query_results = query_results.dup
      @query_calls = []
      @signal_calls = []
    end

    def query(query_name)
      @query_calls << query_name
      raise query_error if query_error
      raise "No query result configured for #{query_name.inspect}" if @query_results.empty?

      @query_results.shift
    end

    define_method(:signal) do |signal_name, *arguments|
      @signal_calls << [signal_name, arguments]
      raise signal_error if signal_error

      true
    end
  end
end

describe ActiveJob::Temporal::DeadLetterQueue do
  let(:client) { DeadLetterQueueSpecSupport::FakeClient.new }
  let(:handle) { DeadLetterQueueSpecSupport::FakeWorkflowHandle.new }
  let(:entry) do
    {
      "id" => "ajdlq:RetryableJob:job-123",
      "state" => "pending",
      "payload" => payload.transform_keys(&:to_s),
      "metadata" => { "original_task_queue" => "critical-workers" }
    }
  end
  let(:payload) do
    {
      job_class: "RetryableJob",
      job_id: "job-123",
      queue_name: "critical",
      arguments: ["raw"],
      retry_policy: { maximum_attempts: 3 },
      scheduled_at: "2026-05-21T10:00:00Z"
    }
  end

  before do
    stub_const("RetryableJob", Class.new)
  end

  describe ".entry" do
    it "queries one dead letter workflow by job class and job ID" do
      result_entry = { "id" => "ajdlq:RetryableJob:job-123" }
      handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new(query_results: [result_entry])
      client.handle_for("ajdlq:RetryableJob:job-123", run_id: "run-1", handle: handle)

      assert_equal result_entry, described_class.entry(RetryableJob, "job-123", run_id: "run-1", client: client)
      assert_equal [["ajdlq:RetryableJob:job-123", "run-1"]], client.workflow_handle_calls
      assert_equal [:entry], handle.query_calls
    end
  end

  describe ".entries" do
    it "lists running dead letter workflows and queries their entries" do
      query = "WorkflowType='ActiveJobTemporalDeadLetterWorkflow' AND ExecutionStatus='Running'"
      workflow = DeadLetterQueueSpecSupport::WorkflowExecution.new(id: "ajdlq:RetryableJob:job-123", run_id: "run-1")
      result_entry = { "id" => "ajdlq:RetryableJob:job-123" }
      handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new(query_results: [result_entry])
      client.list_workflows_for(query, [workflow])
      client.handle_for("ajdlq:RetryableJob:job-123", run_id: "run-1", handle: handle)

      assert_equal [result_entry], described_class.entries(client: client)
      assert_equal [query], client.list_workflows_calls
      assert_equal [["ajdlq:RetryableJob:job-123", "run-1"]], client.workflow_handle_calls
      assert_equal [:entry], handle.query_calls
    end

    it "filters by DLQ task queue and limits queried workflows" do
      query = "WorkflowType='ActiveJobTemporalDeadLetterWorkflow' AND " \
              "ExecutionStatus='Running' AND " \
              "TaskQueue='failed_jobs'"
      result_entry = { "id" => "ajdlq:RetryableJob:job-123" }
      queried_handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new(query_results: [result_entry])
      skipped_handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new
      workflows = [
        DeadLetterQueueSpecSupport::WorkflowExecution.new(id: "ajdlq:RetryableJob:job-123", run_id: "run-1"),
        DeadLetterQueueSpecSupport::WorkflowExecution.new(id: "ajdlq:RetryableJob:job-456", run_id: "run-2")
      ]
      client.list_workflows_for(query, workflows)
      client.handle_for("ajdlq:RetryableJob:job-123", run_id: "run-1", handle: queried_handle)
      client.handle_for("ajdlq:RetryableJob:job-456", run_id: "run-2", handle: skipped_handle)

      assert_equal [result_entry], described_class.entries(queue: "failed_jobs", limit: 1, client: client)
      assert_equal [query], client.list_workflows_calls
      assert_equal [["ajdlq:RetryableJob:job-123", "run-1"]], client.workflow_handle_calls
      assert_equal [:entry], queried_handle.query_calls
      assert_empty skipped_handle.query_calls
    end

    it "rejects task queue names that are unsafe in a visibility query" do
      assert_raises(ArgumentError) { described_class.entries(queue: "failed' OR '1'='1", client: client) }
      assert_empty client.list_workflows_calls
    end

    it "surfaces query failures instead of dropping the entry" do
      query = "WorkflowType='ActiveJobTemporalDeadLetterWorkflow' AND ExecutionStatus='Running'"
      broken_handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new
      broken_handle.query_error = Temporalio::Error::WorkflowQueryFailedError
      workflow = DeadLetterQueueSpecSupport::WorkflowExecution.new(id: "ajdlq:RetryableJob:job-broken",
                                                                   run_id: "run-broken")
      client.list_workflows_for(query, [workflow])
      client.handle_for("ajdlq:RetryableJob:job-broken", run_id: "run-broken", handle: broken_handle)

      assert_raises(Temporalio::Error::WorkflowQueryFailedError) { described_class.entries(client: client) }
    end

    it "queries workflow entries concurrently and preserves list order" do
      query = "WorkflowType='ActiveJobTemporalDeadLetterWorkflow' AND ExecutionStatus='Running'"
      workflows = Array.new(10) do |index|
        DeadLetterQueueSpecSupport::WorkflowExecution.new(id: "ajdlq:RetryableJob:job-#{index}",
                                                          run_id: "run-#{index}")
      end
      expected_entries = workflows.each_with_index.map do |workflow, index|
        entry = { "id" => workflow.id }
        handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new(query_results: [entry])
        client.handle_for(workflow.id, run_id: "run-#{index}", handle: handle)
        entry
      end
      client.list_workflows_for(query, workflows)

      assert_equal expected_entries, described_class.entries(client: client)
    end
  end

  describe ".retry" do
    let(:logger_calls) { call_recorded_method(ActiveJob::Temporal::Logger, :log_event) }

    before do
      logger_calls
    end

    it "starts a new ActiveJob workflow and marks the entry retried" do
      handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new(query_results: [entry])
      client.handle_for("ajdlq:RetryableJob:job-123", handle: handle)

      workflow_id = described_class.retry(RetryableJob, "job-123", client: client)

      assert_equal "ajdlq-retry:ajdlq:RetryableJob:job-123", workflow_id
      assert_equal 1, client.start_workflow_calls.size
      start_workflow_call = client.start_workflow_calls.first
      assert_equal(
        [
          ActiveJob::Temporal::WorkflowTypes::ACTIVE_JOB,
          {
            "job_class" => "RetryableJob",
            "job_id" => "job-123",
            "queue_name" => "critical",
            "arguments" => ["raw"],
            "retry_policy" => { maximum_attempts: 3 }
          }
        ],
        start_workflow_call.fetch(:arguments)
      )
      assert_equal(
        {
          id: workflow_id,
          task_queue: "critical-workers",
          id_conflict_policy: Temporalio::WorkflowIDConflictPolicy::FAIL
        },
        start_workflow_call.fetch(:keywords)
      )
      assert_equal [[:mark_retried, [workflow_id]]], handle.signal_calls
      assert_equal 1, logger_calls.calls_for(:log_event).size
      log_call = logger_calls.calls_for(:log_event).first
      assert_equal "dead_letter_retry_requested", log_call.arguments.first
      assert_hash_includes(
        {
          entry_id: "ajdlq:RetryableJob:job-123",
          workflow_id: workflow_id,
          job_class: "RetryableJob",
          job_id: "job-123",
          task_queue: "critical-workers",
          duplicate: false
        },
        log_call.arguments.fetch(1)
      )
    end

    it "returns success when mark retried signal fails after applying" do
      workflow_id = "ajdlq-retry:ajdlq:RetryableJob:job-123"
      retried_entry = entry.merge("state" => "retried", "retry_workflow_id" => workflow_id)
      signal_error = StandardError.new("signal failed")
      handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new(query_results: [entry, retried_entry])
      handle.signal_error = signal_error
      client.handle_for("ajdlq:RetryableJob:job-123", handle: handle)

      assert_equal workflow_id, described_class.retry(RetryableJob, "job-123", client: client)
      assert_equal %i[entry entry], handle.query_calls
      assert_equal [[:mark_retried, [workflow_id]]], handle.signal_calls
    end

    it "raises a marked retry error when the retry workflow may be running but the entry remains pending" do
      workflow_id = "ajdlq-retry:ajdlq:RetryableJob:job-123"
      signal_error = StandardError.new("signal failed")
      handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new(query_results: [entry, entry])
      handle.signal_error = signal_error
      client.handle_for("ajdlq:RetryableJob:job-123", handle: handle)

      error = assert_raises(ActiveJob::Temporal::Error) do
        described_class.retry(RetryableJob, "job-123", client: client)
      end
      assert_includes error.message, workflow_id
      assert_includes error.message, "could not mark dead letter entry"
      assert_same signal_error, error.cause
      assert_equal %i[entry entry], handle.query_calls
      assert_equal [[:mark_retried, [workflow_id]]], handle.signal_calls
    end

    it "raises a marked retry error when an already-started retry workflow cannot be marked" do
      workflow_id = "ajdlq-retry:ajdlq:RetryableJob:job-123"
      already_started = Temporalio::Error::WorkflowAlreadyStartedError.new(
        workflow_id: workflow_id,
        workflow_type: "ActiveJobTemporalAjWorkflow",
        run_id: "retry-run-1"
      )
      signal_error = StandardError.new("signal failed")
      handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new(query_results: [entry, entry])
      handle.signal_error = signal_error
      client.handle_for("ajdlq:RetryableJob:job-123", handle: handle)
      client.start_workflow_error = already_started

      error = assert_raises(ActiveJob::Temporal::Error) do
        described_class.retry(RetryableJob, "job-123", client: client)
      end
      assert_includes error.message, workflow_id
      assert_same signal_error, error.cause
      assert_equal 1, client.start_workflow_calls.size
      assert_equal %i[entry entry], handle.query_calls
      assert_equal [[:mark_retried, [workflow_id]]], handle.signal_calls
    end

    it "marks the entry retried when another operator already started the deterministic retry workflow" do
      workflow_id = "ajdlq-retry:ajdlq:RetryableJob:job-123"
      already_started = Temporalio::Error::WorkflowAlreadyStartedError.new(
        workflow_id: workflow_id,
        workflow_type: "ActiveJobTemporalAjWorkflow",
        run_id: "retry-run-1"
      )
      handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new(query_results: [entry])
      client.handle_for("ajdlq:RetryableJob:job-123", handle: handle)
      client.start_workflow_error = already_started

      assert_equal workflow_id, described_class.retry(RetryableJob, "job-123", client: client)
      assert_equal [[:mark_retried, [workflow_id]]], handle.signal_calls
      log_call = logger_calls.calls_for(:log_event).first
      assert_equal "dead_letter_retry_requested", log_call.arguments.first
      assert_hash_includes({ workflow_id: workflow_id, duplicate: true }, log_call.arguments.fetch(1))
    end

    it "marks the entry retried when Temporal reports an already-exists RPC duplicate" do
      workflow_id = "ajdlq-retry:ajdlq:RetryableJob:job-123"
      already_exists = Class.new(StandardError) do
        attr_reader :code

        def initialize
          super("Workflow execution already started")
          @code = Temporalio::Error::RPCError::Code::ALREADY_EXISTS
        end
      end
      handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new(query_results: [entry])
      client.handle_for("ajdlq:RetryableJob:job-123", handle: handle)
      client.start_workflow_error = already_exists

      assert_equal workflow_id, described_class.retry(RetryableJob, "job-123", client: client)
      assert_equal [[:mark_retried, [workflow_id]]], handle.signal_calls
      log_call = logger_calls.calls_for(:log_event).first
      assert_equal "dead_letter_retry_requested", log_call.arguments.first
      assert_hash_includes({ workflow_id: workflow_id, duplicate: true }, log_call.arguments.fetch(1))
    end

    it "returns the existing retry workflow ID for an already retried entry" do
      retried_entry = entry.merge("state" => "retried", "retry_workflow_id" => "retry-workflow-1")
      handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new(query_results: [retried_entry])
      client.handle_for("ajdlq:RetryableJob:job-123", handle: handle)

      assert_equal "retry-workflow-1", described_class.retry(RetryableJob, "job-123", client: client)
      assert_empty client.start_workflow_calls
      log_call = logger_calls.calls_for(:log_event).first
      assert_equal "dead_letter_retry_requested", log_call.arguments.first
      assert_hash_includes({ workflow_id: "retry-workflow-1", duplicate: true }, log_call.arguments.fetch(1))
    end

    it "returns the same retry workflow ID when the entry is retried twice" do
      workflow_id = "ajdlq-retry:ajdlq:RetryableJob:job-123"
      retried_entry = entry.merge("state" => "retried", "retry_workflow_id" => workflow_id)
      handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new(query_results: [entry, retried_entry])
      client.handle_for("ajdlq:RetryableJob:job-123", handle: handle)

      assert_equal workflow_id, described_class.retry(RetryableJob, "job-123", client: client)
      assert_equal workflow_id, described_class.retry(RetryableJob, "job-123", client: client)
      assert_equal 1, client.start_workflow_calls.size
      assert_equal [[:mark_retried, [workflow_id]]], handle.signal_calls
    end

    it "does not retry discarded entries" do
      discarded_entry = entry.merge("state" => "discarded")
      handle = DeadLetterQueueSpecSupport::FakeWorkflowHandle.new(query_results: [discarded_entry])
      client.handle_for("ajdlq:RetryableJob:job-123", handle: handle)

      error = assert_raises(ActiveJob::Temporal::Error) do
        described_class.retry(RetryableJob, "job-123", client: client)
      end
      assert_match(/state "discarded"/, error.message)
      assert_empty client.start_workflow_calls
    end
  end

  describe ".discard" do
    it "signals the dead letter workflow to discard the entry" do
      client.handle_for("ajdlq:RetryableJob:job-123", handle: handle)

      described_class.discard(RetryableJob, "job-123", reason: "handled elsewhere", client: client)

      assert_equal [[:discard, ["handled elsewhere"]]], handle.signal_calls
    end
  end
end
