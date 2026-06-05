# frozen_string_literal: true

require "spec_helper"
require "timeout"
require_relative "../fixtures/sample_jobs"

unless defined?(Temporalio::Error::RPCError)
  module Temporalio
    module Error
      class RPCError < StandardError
        module Code
          NOT_FOUND = 5
          PERMISSION_DENIED = 7
        end

        attr_reader :code

        def initialize(message = "RPC error", code: Code::NOT_FOUND, _raw_grpc_status: nil)
          super(message)
          @code = code
        end
      end
    end
  end
end

module CancelSpecSupport
  Page = Struct.new(:executions, :next_page_token)
  WorkflowExecution = Struct.new(:id, :run_id)

  class WorkflowInfo
    attr_reader :id

    def initialize(id = nil)
      @id = id
    end
  end

  class RecordingClient
    attr_reader :calls

    def initialize
      @calls = MinitestHelpers::CallRecorder.new
      @workflow_handles = {}
      @workflow_lists = {}
      @workflow_list_errors = {}
      @workflow_pages = {}
      @workflow_page_errors = {}
    end

    def register_workflow_handle(workflow_id, handle:, run_id: nil)
      @workflow_handles[[workflow_id, run_id]] = handle
    end

    def register_workflows(query, workflows)
      @workflow_lists[query] = workflows
    end

    def raise_on_list_workflows(query, error)
      @workflow_list_errors[query] = error
    end

    def register_workflow_page(query, page_size:, next_page_token:, page:)
      @workflow_pages[[query, page_size, next_page_token]] = page
    end

    def raise_on_list_workflow_page(query, page_size:, next_page_token:, error:)
      @workflow_page_errors[[query, page_size, next_page_token]] = error
    end

    def workflow_handle(workflow_id, run_id: nil)
      calls.record(:workflow_handle, workflow_id, run_id: run_id)
      @workflow_handles.fetch([workflow_id, run_id])
    end

    def list_workflows(query)
      calls.record(:list_workflows, query)
      raise @workflow_list_errors.fetch(query) if @workflow_list_errors.key?(query)

      @workflow_lists.fetch(query, [])
    end

    def list_workflow_page(query, page_size:, next_page_token:)
      calls.record(:list_workflow_page, query, page_size: page_size, next_page_token: next_page_token)
      key = [query, page_size, next_page_token]
      raise @workflow_page_errors.fetch(key) if @workflow_page_errors.key?(key)

      @workflow_pages.fetch(key)
    end
  end

  class RecordingHandle
    attr_reader :calls

    def initialize
      @calls = MinitestHelpers::CallRecorder.new
      @errors = {}
    end

    def raise_on(method_name, error)
      @errors[method_name] = error
    end

    def cancel
      record_call(:cancel)
    end

    def terminate(reason = nil)
      record_call(:terminate, reason)
    end

    private

    def record_call(method_name, *)
      calls.record(method_name, *)
      error = @errors[method_name]
      raise(error.respond_to?(:call) ? error.call : error) if error
    end
  end
end

describe ActiveJob::Temporal::Cancel do
  describe ".cancel" do
    let(:job_class) { SimpleJob }
    let(:job_id) { "550e8400-e29b-41d4-a716-446655440000" }
    let(:workflow_id) { "ajwf:#{job_class.name}:#{job_id}" }
    let(:running_query) { "ajClass='#{job_class.name}' AND ajJobId='#{job_id}' AND ExecutionStatus='Running'" }
    let(:closed_query) do
      "ajClass='#{job_class.name}' AND ajJobId='#{job_id}' AND " \
        "ExecutionStatus IN ('Completed', 'Failed', 'Cancelled', 'Terminated', 'TimedOut', 'ContinuedAsNew')"
    end
    let(:client) { CancelSpecSupport::RecordingClient.new }
    let(:handle) { CancelSpecSupport::RecordingHandle.new }

    before do
      call_recorded_method(ActiveJob::Temporal, :client, returns: client)
      client.register_workflow_handle(workflow_id, handle: handle)
      client.register_workflows(running_query, [])
      client.register_workflows(closed_query, [])
      call_recorded_method(ActiveJob::Temporal::Logger, :log_event)
      @logger_info_calls = call_recorded_method(ActiveJob::Temporal::Logger, :info)
      @logger_warn_calls = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      @audit_record_calls = call_recorded_method(ActiveJob::Temporal::AuditLog, :record)
    end

    describe "when the workflow is running" do
      let(:workflow_info) { CancelSpecSupport::WorkflowInfo.new }

      before do
        client.register_workflows(running_query, [workflow_info])
      end

      it "cancels the workflow via Temporal client" do
        described_class.cancel(job_class, job_id)

        assert_called_with(client.calls, :workflow_handle, workflow_id, run_id: nil)
        assert_called_with(handle.calls, :cancel)
      end

      it "escapes job class names when querying workflows" do
        dynamic_job_class = Class.new(ActiveJob::Base)
        unsafe_name = "CancelJob' OR '1'='1"
        escaped_query = "ajClass='CancelJob'' OR ''1''=''1' AND ajJobId='#{job_id}' " \
                        "AND ExecutionStatus='Running'"
        workflow_info = CancelSpecSupport::WorkflowInfo.new("workflow-1")

        dynamic_job_class.define_singleton_method(:name) { unsafe_name }
        client.register_workflows(escaped_query, [workflow_info])
        client.register_workflow_handle("workflow-1", handle: handle)

        described_class.cancel(dynamic_job_class, job_id)

        assert_called_with(client.calls, :list_workflows, escaped_query)
        assert_called_with(handle.calls, :cancel)
      end

      it "logs a cancellation request event" do
        described_class.cancel(job_class, job_id)

        assert_called_with(
          @logger_info_calls,
          :info,
          "cancellation_requested",
          workflow_id: workflow_id,
          job_class: job_class.name,
          job_id: job_id
        )
      end

      it "records a cancellation audit event" do
        described_class.cancel(job_class, job_id)

        assert_called_with(
          @audit_record_calls,
          :record,
          "job.cancelled",
          workflow_id: workflow_id,
          job_class: job_class.name,
          job_id: job_id,
          status: "requested"
        )
      end

      it "wraps cancellation RPC failures in TemporalConnectionError" do
        cancellation_error = Temporalio::Error::RPCError.new(
          "permission denied",
          code: Temporalio::Error::RPCError::Code::PERMISSION_DENIED,
          raw_grpc_status: nil
        )
        handle.raise_on(:cancel, cancellation_error)

        error = assert_raises(ActiveJob::Temporal::TemporalConnectionError) do
          described_class.cancel(job_class, job_id)
        end
        assert_includes error.message, "Failed to cancel Temporal workflow for job_id #{job_id}"
        assert_includes error.message, "permission denied"
        assert_same cancellation_error, error.cause
      end

      it "keeps cancellation RPC not-found failures as WorkflowNotFoundError" do
        not_found_error = Temporalio::Error::RPCError.new(
          "not found",
          code: Temporalio::Error::RPCError::Code::NOT_FOUND,
          raw_grpc_status: nil
        )
        handle.raise_on(:cancel, not_found_error)

        error = assert_raises(ActiveJob::Temporal::WorkflowNotFoundError) do
          described_class.cancel(job_class, job_id)
        end
        assert_includes error.message, "No workflow found for job_id #{job_id}"
        assert_same not_found_error, error.cause
      end

      describe "when the workflow uses a custom workflow ID" do
        let(:custom_workflow_id) { "tenant-42:ajwf:#{job_class.name}:#{job_id}" }
        let(:workflow_info) { CancelSpecSupport::WorkflowInfo.new(custom_workflow_id) }

        before do
          client.register_workflow_handle(custom_workflow_id, handle: handle)
        end

        it "cancels the workflow returned by Temporal search" do
          described_class.cancel(job_class, job_id)

          assert_called_with(client.calls, :workflow_handle, custom_workflow_id, run_id: nil)
          assert_called_with(handle.calls, :cancel)
        end
      end
    end

    describe "when the workflow is already completed" do
      let(:workflow_info) { CancelSpecSupport::WorkflowInfo.new }

      before do
        client.register_workflows(running_query, [])
        client.register_workflows(closed_query, [workflow_info])
      end

      it "returns false and does not attempt to cancel" do
        result = described_class.cancel(job_class, job_id)

        assert_equal false, result
        refute_called(handle.calls, :cancel)
      end

      it "logs a warning that the workflow is already completed" do
        described_class.cancel(job_class, job_id)

        assert_called_with(
          @logger_warn_calls,
          :warn,
          "cancellation_workflow_already_completed",
          workflow_id: workflow_id,
          job_class: job_class.name,
          job_id: job_id,
          status: "completed"
        )
      end
    end

    describe "when the workflow never existed" do
      before do
        client.register_workflows(running_query, [])
        client.register_workflows(closed_query, [])
      end

      it "raises WorkflowNotFoundError" do
        error = assert_raises(ActiveJob::Temporal::WorkflowNotFoundError) do
          described_class.cancel(job_class, job_id)
        end
        assert_match(/No workflow found for job_id #{job_id}/, error.message)
      end

      it "does not cancel a workflow from another job class with the same job ID" do
        other_workflow_id = "ajwf:ScheduledJob:#{job_id}"
        other_workflow_info = CancelSpecSupport::WorkflowInfo.new(other_workflow_id)
        broad_running_query = "ajJobId='#{job_id}' AND ExecutionStatus='Running'"

        client.register_workflows(broad_running_query, [other_workflow_info])
        client.register_workflow_handle(other_workflow_id, handle: handle)

        assert_raises(ActiveJob::Temporal::WorkflowNotFoundError) do
          described_class.cancel(job_class, job_id)
        end

        other_workflow_calls = client.calls.calls_for(:workflow_handle).select do |call|
          call.arguments == [other_workflow_id]
        end
        assert_empty other_workflow_calls
      end
    end

    describe "when Temporal connection fails" do
      let(:connection_error) { StandardError.new("Connection refused") }

      before do
        client.raise_on_list_workflows(running_query, connection_error)
      end

      it "raises TemporalConnectionError" do
        error = assert_raises(ActiveJob::Temporal::TemporalConnectionError) do
          described_class.cancel(job_class, job_id)
        end
        assert_match(/Failed to query Temporal workflows for job_id #{job_id}/, error.message)
      end
    end

    describe "job_id validation" do
      describe "when job_id requires query escaping" do
        let(:custom_job_id) { "test' OR '1'='1" }
        let(:escaped_running_query) do
          "ajClass='#{job_class.name}' AND ajJobId='test'' OR ''1''=''1' AND ExecutionStatus='Running'"
        end
        let(:escaped_workflow_id) { "ajwf:#{job_class.name}:#{custom_job_id}" }
        let(:workflow_info) { CancelSpecSupport::WorkflowInfo.new }

        before do
          client.register_workflows(escaped_running_query, [workflow_info])
          client.register_workflow_handle(escaped_workflow_id, handle: handle)
        end

        it "quotes the job ID before querying Temporal" do
          described_class.cancel(job_class, custom_job_id)

          assert_called_with(client.calls, :list_workflows, escaped_running_query)
          assert_called_with(handle.calls, :cancel)
        end
      end

      describe "when job_id is a schedule-style execution ID" do
        let(:schedule_job_id) do
          "ajschwf:daily-report-2026-05-25T20:07:45Z:019e60c0-2587-710d-8633-a0f90e9dd6f9"
        end
        let(:schedule_workflow_id) { "ajschwf:daily-report-2026-05-25T20:07:45Z" }
        let(:schedule_run_id) { "019e60c0-2587-710d-8633-a0f90e9dd6f9" }

        before do
          client.register_workflow_handle(schedule_workflow_id, run_id: schedule_run_id, handle: handle)
        end

        it "accepts the schedule-style job ID" do
          assert_nothing_raised { described_class.cancel(job_class, schedule_job_id) }
          assert_called_with(handle.calls, :cancel)
          refute_called(client.calls, :list_workflows)
        end

        it "wraps schedule execution cancellation RPC failures in TemporalConnectionError" do
          cancellation_error = Temporalio::Error::RPCError.new(
            "namespace not found",
            code: Temporalio::Error::RPCError::Code::PERMISSION_DENIED,
            raw_grpc_status: nil
          )
          handle.raise_on(:cancel, cancellation_error)

          error = assert_raises(ActiveJob::Temporal::TemporalConnectionError) do
            described_class.cancel(job_class, schedule_job_id)
          end
          assert_includes error.message, "Failed to cancel Temporal workflow for job_id #{schedule_job_id}"
          assert_includes error.message, "namespace not found"
          assert_same cancellation_error, error.cause
        end
      end

      describe "when job_id is blank" do
        let(:blank_job_id) { " " }

        it "raises ArgumentError with helpful message" do
          error = assert_raises(ArgumentError) { described_class.cancel(job_class, blank_job_id) }
          assert_match(/job_id must not be blank/, error.message)

          refute_called(client.calls, :list_workflows)
        end
      end

      describe "when job_id is nil" do
        let(:nil_job_id) { nil }

        it "raises ArgumentError" do
          error = assert_raises(ArgumentError) { described_class.cancel(job_class, nil_job_id) }
          assert_match(/job_id must be a String/, error.message)
        end
      end

      describe "when job_id is an integer" do
        let(:integer_job_id) { 12_345 }

        it "raises ArgumentError" do
          error = assert_raises(ArgumentError) { described_class.cancel(job_class, integer_job_id) }
          assert_match(/job_id must be a String/, error.message)
        end
      end

      describe "when job_id contains control characters" do
        let(:control_job_id) { "job\n123" }

        it "raises ArgumentError before making any queries" do
          error = assert_raises(ArgumentError) { described_class.cancel(job_class, control_job_id) }
          assert_match(/control characters/, error.message)

          refute_called(client.calls, :list_workflows)
        end
      end

      describe "when job_id is too long" do
        let(:long_job_id) { "a" * (ActiveJob::Temporal::JobIdValidation::MAX_JOB_ID_LENGTH + 1) }

        it "raises ArgumentError before making any queries" do
          error = assert_raises(ArgumentError) { described_class.cancel(job_class, long_job_id) }
          assert_match(/maximum length/, error.message)

          refute_called(client.calls, :list_workflows)
        end
      end

      describe "when job_id is a valid UUID (lowercase)" do
        let(:valid_uuid) { "550e8400-e29b-41d4-a716-446655440000" }
        let(:workflow_info) { CancelSpecSupport::WorkflowInfo.new }

        before do
          client.register_workflows(
            "ajClass='#{job_class.name}' AND ajJobId='#{valid_uuid}' AND ExecutionStatus='Running'",
            [workflow_info]
          )
        end

        it "accepts the UUID and proceeds with cancellation" do
          assert_nothing_raised { described_class.cancel(job_class, valid_uuid) }
        end
      end

      describe "when job_id is a valid UUID (uppercase)" do
        let(:valid_uuid_uppercase) { "550E8400-E29B-41D4-A716-446655440000" }
        let(:workflow_info) { CancelSpecSupport::WorkflowInfo.new }
        let(:workflow_id_uppercase) { "ajwf:#{job_class.name}:#{valid_uuid_uppercase}" }

        before do
          client.register_workflows(
            "ajClass='#{job_class.name}' AND ajJobId='#{valid_uuid_uppercase}' AND ExecutionStatus='Running'",
            [workflow_info]
          )
          client.register_workflow_handle(workflow_id_uppercase, handle: handle)
        end

        it "accepts the UUID and proceeds with cancellation" do
          assert_nothing_raised { described_class.cancel(job_class, valid_uuid_uppercase) }
        end
      end

      describe "when job_id is a valid UUID (mixed case)" do
        let(:valid_uuid_mixed) { "550e8400-E29B-41d4-A716-446655440000" }
        let(:workflow_info) { CancelSpecSupport::WorkflowInfo.new }
        let(:workflow_id_mixed) { "ajwf:#{job_class.name}:#{valid_uuid_mixed}" }

        before do
          client.register_workflows(
            "ajClass='#{job_class.name}' AND ajJobId='#{valid_uuid_mixed}' AND ExecutionStatus='Running'",
            [workflow_info]
          )
          client.register_workflow_handle(workflow_id_mixed, handle: handle)
        end

        it "accepts the UUID and proceeds with cancellation" do
          assert_nothing_raised { described_class.cancel(job_class, valid_uuid_mixed) }
        end
      end
    end
  end

  describe ".cancel_all" do
    let(:job_class) { SimpleJob }

    it "delegates to cancel_where with the job class search attribute" do
      summary = { terminated: 1, failed: 0, errors: [] }
      cancel_where_calls = call_recorded_method(described_class, :cancel_where, returns: summary)

      result = described_class.cancel_all(job_class)

      assert_equal summary, result
      assert_called_with(cancel_where_calls, :cancel_where, ajClass: job_class.name)
    end

    it "terminates running workflows matching the job class" do
      client = CancelSpecSupport::RecordingClient.new
      handle = CancelSpecSupport::RecordingHandle.new
      workflow_execution = CancelSpecSupport::WorkflowExecution.new("workflow-1", "run-1")
      query = "ajClass='#{job_class.name}' AND ExecutionStatus='Running'"

      call_recorded_method(ActiveJob::Temporal, :client, returns: client)
      call_recorded_method(ActiveJob::Temporal::AuditLog, :record)
      client.register_workflow_page(
        query,
        page_size: 100,
        next_page_token: nil,
        page: CancelSpecSupport::Page.new([workflow_execution], nil)
      )
      client.register_workflow_handle("workflow-1", run_id: "run-1", handle: handle)

      result = described_class.cancel_all(job_class)

      assert_equal({ terminated: 1, failed: 0, errors: [] }, result)
      assert_called_with(handle.calls, :terminate, "ActiveJob::Temporal.cancel_where")
    end

    it "rejects unnamed job classes" do
      unnamed_class = Class.new

      error = assert_raises(ArgumentError) { described_class.cancel_all(unnamed_class) }
      assert_match(/job_class must be a named class/, error.message)
    end
  end

  describe ".cancel_where" do
    let(:client) { CancelSpecSupport::RecordingClient.new }
    let(:handle) { CancelSpecSupport::RecordingHandle.new }

    before do
      call_recorded_method(ActiveJob::Temporal, :client, returns: client)
      @audit_record_calls = call_recorded_method(ActiveJob::Temporal::AuditLog, :record)
    end

    it "terminates running workflows matching job class" do
      workflow_execution = CancelSpecSupport::WorkflowExecution.new("workflow-1", "run-1")
      query = "ajClass='#{SimpleJob.name}' AND ExecutionStatus='Running'"

      client.register_workflow_page(
        query,
        page_size: 100,
        next_page_token: nil,
        page: CancelSpecSupport::Page.new([workflow_execution], nil)
      )
      client.register_workflow_handle("workflow-1", run_id: "run-1", handle: handle)

      result = described_class.cancel_where(ajClass: SimpleJob.name)

      assert_equal({ terminated: 1, failed: 0, errors: [] }, result)
      assert_called_with(handle.calls, :terminate, "ActiveJob::Temporal.cancel_where")
      assert_called_with(
        @audit_record_calls,
        :record,
        "job.cancelled",
        workflow_id: "workflow-1",
        run_id: "run-1",
        status: "terminated",
        reason: "ActiveJob::Temporal.cancel_where"
      )
    end

    it "supports queue and tenant search attributes" do
      query = "ajQueue='low_priority' AND ajTenantId=123 AND ExecutionStatus='Running'"

      client.register_workflow_page(
        query,
        page_size: 100,
        next_page_token: nil,
        page: CancelSpecSupport::Page.new([], nil)
      )

      result = described_class.cancel_where(ajQueue: "low_priority", ajTenantId: 123)

      assert_equal({ terminated: 0, failed: 0, errors: [] }, result)
    end

    it "handles paginated workflow results" do
      first_workflow = CancelSpecSupport::WorkflowExecution.new("workflow-1", "run-1")
      second_workflow = CancelSpecSupport::WorkflowExecution.new("workflow-2", "run-2")
      query = "ajQueue='bulk' AND ExecutionStatus='Running'"
      first_handle = CancelSpecSupport::RecordingHandle.new
      second_handle = CancelSpecSupport::RecordingHandle.new

      client.register_workflow_page(
        query,
        page_size: 100,
        next_page_token: nil,
        page: CancelSpecSupport::Page.new([first_workflow], "next-page")
      )
      client.register_workflow_page(
        query,
        page_size: 100,
        next_page_token: "next-page",
        page: CancelSpecSupport::Page.new([second_workflow], nil)
      )
      client.register_workflow_handle("workflow-1", run_id: "run-1", handle: first_handle)
      client.register_workflow_handle("workflow-2", run_id: "run-2", handle: second_handle)

      result = described_class.cancel_where(ajQueue: "bulk")

      assert_equal({ terminated: 2, failed: 0, errors: [] }, result)
      assert_called_with(first_handle.calls, :terminate, "ActiveJob::Temporal.cancel_where")
      assert_called_with(second_handle.calls, :terminate, "ActiveJob::Temporal.cancel_where")
    end

    it "records per-workflow termination failures" do
      successful_workflow = CancelSpecSupport::WorkflowExecution.new("workflow-1", "run-1")
      failing_workflow = CancelSpecSupport::WorkflowExecution.new("workflow-2", "run-2")
      query = "ajQueue='bulk' AND ExecutionStatus='Running'"
      successful_handle = CancelSpecSupport::RecordingHandle.new
      failing_handle = CancelSpecSupport::RecordingHandle.new

      failing_handle.raise_on(:terminate, -> { StandardError.new("permission denied") })
      client.register_workflow_page(
        query,
        page_size: 100,
        next_page_token: nil,
        page: CancelSpecSupport::Page.new([successful_workflow, failing_workflow], nil)
      )
      client.register_workflow_handle("workflow-1", run_id: "run-1", handle: successful_handle)
      client.register_workflow_handle("workflow-2", run_id: "run-2", handle: failing_handle)

      result = described_class.cancel_where(ajQueue: "bulk")

      assert_equal(
        {
          terminated: 1,
          failed: 1,
          errors: [
            {
              workflow_id: "workflow-2",
              run_id: "run-2",
              error: "StandardError: permission denied"
            }
          ]
        },
        result
      )
    end

    it "terminates workflows from the same page concurrently" do
      workflow_count = 4
      query = "ajQueue='bulk' AND ExecutionStatus='Running'"
      started_terminations = Queue.new
      release_terminations = Queue.new
      workflows = Array.new(workflow_count) do |index|
        CancelSpecSupport::WorkflowExecution.new("workflow-#{index}", "run-#{index}")
      end
      handles = workflows.to_h do |workflow|
        [
          workflow.id,
          Class.new do
            define_method(:terminate) do |_reason|
              started_terminations << workflow.id
              release_terminations.pop
            end
          end.new
        ]
      end

      client.register_workflow_page(
        query,
        page_size: 100,
        next_page_token: nil,
        page: CancelSpecSupport::Page.new(workflows, nil)
      )
      workflows.each do |workflow|
        client.register_workflow_handle(workflow.id, run_id: workflow.run_id, handle: handles.fetch(workflow.id))
      end

      cancellation_thread = Thread.new { described_class.cancel_where(ajQueue: "bulk") }

      begin
        assert_nothing_raised do
          Timeout.timeout(1) do
            2.times { started_terminations.pop }
          end
        end
      ensure
        workflow_count.times { release_terminations << true }
      end

      assert_equal({ terminated: workflow_count, failed: 0, errors: [] }, cancellation_thread.value)
    end

    it "caps recorded termination errors while counting every failure" do
      error_limit = ActiveJob::Temporal::Cancel::BatchCanceller::MAX_REPORTED_ERRORS
      workflow_count = error_limit + 5
      query = "ajQueue='bulk' AND ExecutionStatus='Running'"
      workflows = Array.new(workflow_count) do |index|
        CancelSpecSupport::WorkflowExecution.new("workflow-#{index}", "run-#{index}")
      end
      failing_handle = CancelSpecSupport::RecordingHandle.new

      failing_handle.raise_on(:terminate, -> { StandardError.new("permission denied") })
      client.register_workflow_page(
        query,
        page_size: 100,
        next_page_token: nil,
        page: CancelSpecSupport::Page.new(workflows, nil)
      )
      workflows.each do |workflow|
        client.register_workflow_handle(workflow.id, run_id: workflow.run_id, handle: failing_handle)
      end

      result = described_class.cancel_where(ajQueue: "bulk")

      assert_equal 0, result[:terminated]
      assert_equal workflow_count, result[:failed]
      assert_equal error_limit, result[:errors].size
      result[:errors].each do |recorded_error|
        assert_hash_includes({ error: "StandardError: permission denied" }, recorded_error)
      end
    end

    it "escapes string search attribute values" do
      query = "ajQueue='vip''queue' AND ExecutionStatus='Running'"

      client.register_workflow_page(
        query,
        page_size: 100,
        next_page_token: nil,
        page: CancelSpecSupport::Page.new([], nil)
      )

      described_class.cancel_where(ajQueue: "vip'queue")

      assert_called_with(client.calls, :list_workflow_page, query, page_size: 100, next_page_token: nil)
    end

    it "rejects unsupported search attributes before querying Temporal" do
      error = assert_raises(ArgumentError) { described_class.cancel_where(customAttribute: "value") }
      assert_match(/Unsupported search attribute/, error.message)

      refute_called(client.calls, :list_workflow_page)
    end

    it "rejects empty filters" do
      error = assert_raises(ArgumentError) { described_class.cancel_where({}) }
      assert_match(/requires at least one search attribute/, error.message)
    end

    it "wraps list failures in TemporalConnectionError" do
      query = "ajQueue='bulk' AND ExecutionStatus='Running'"

      client.raise_on_list_workflow_page(
        query,
        page_size: 100,
        next_page_token: nil,
        error: StandardError.new("connection refused")
      )

      error = assert_raises(ActiveJob::Temporal::TemporalConnectionError) do
        described_class.cancel_where(ajQueue: "bulk")
      end
      assert_match(/batch cancellation: connection refused/, error.message)
    end
  end
end

describe ActiveJob::Temporal do
  describe ".cancel_all" do
    it "delegates to the cancellation module" do
      summary = { terminated: 1, failed: 0, errors: [] }
      cancel_all_calls = call_recorded_method(ActiveJob::Temporal::Cancel, :cancel_all, returns: summary)

      assert_equal summary, described_class.cancel_all(SimpleJob)
      assert_called_with(cancel_all_calls, :cancel_all, SimpleJob)
    end
  end

  describe ".cancel_where" do
    it "delegates to the cancellation module" do
      filters = { ajQueue: "default" }
      summary = { terminated: 1, failed: 0, errors: [] }
      cancel_where_calls = call_recorded_method(ActiveJob::Temporal::Cancel, :cancel_where, returns: summary)

      assert_equal summary, described_class.cancel_where(filters)
      assert_called_with(cancel_where_calls, :cancel_where, filters)
    end
  end
end
