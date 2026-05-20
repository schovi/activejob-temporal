# frozen_string_literal: true

require "spec_helper"
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

RSpec.describe ActiveJob::Temporal::Cancel do
  describe ".cancel" do
    let(:job_class) { SimpleJob }
    let(:job_id) { "550e8400-e29b-41d4-a716-446655440000" }
    let(:workflow_id) { "ajwf:#{job_class.name}:#{job_id}" }
    let(:running_query) { "ajClass='#{job_class.name}' AND ajJobId='#{job_id}' AND ExecutionStatus='Running'" }
    let(:closed_query) do
      "ajClass='#{job_class.name}' AND ajJobId='#{job_id}' AND " \
        "ExecutionStatus IN ('Completed', 'Failed', 'Cancelled', 'Terminated', 'TimedOut', 'ContinuedAsNew')"
    end
    let(:temporal_client_class) do
      Class.new do
        def workflow_handle(_workflow_id); end
        def list_workflows(_query = nil); end
      end
    end
    let(:workflow_handle_class) do
      Class.new do
        def cancel; end
      end
    end
    let(:client) { instance_double(temporal_client_class) }
    let(:handle) { instance_double(workflow_handle_class) }

    before do
      allow(ActiveJob::Temporal).to receive(:client).and_return(client)
      allow(client).to receive(:workflow_handle).with(workflow_id).and_return(handle)
      allow(client).to receive(:list_workflows).and_return([])
      allow(handle).to receive(:cancel)
      allow(ActiveJob::Temporal::Logger).to receive(:log_event)
      allow(ActiveJob::Temporal::Logger).to receive(:info)
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      allow(ActiveJob::Temporal::AuditLog).to receive(:record)
    end

    context "when the workflow is running" do
      let(:workflow_info) { double("WorkflowInfo") }

      before do
        # Mock running workflow
        allow(client).to receive(:list_workflows)
          .with(running_query)
          .and_return([workflow_info])
      end

      it "cancels the workflow via Temporal client" do
        described_class.cancel(job_class, job_id)

        expect(client).to have_received(:workflow_handle).with(workflow_id)
        expect(handle).to have_received(:cancel)
      end

      it "logs a cancellation request event" do
        described_class.cancel(job_class, job_id)

        expect(ActiveJob::Temporal::Logger).to have_received(:info).with(
          "cancellation_requested",
          workflow_id: workflow_id,
          job_class: job_class.name,
          job_id: job_id
        )
      end

      it "records a cancellation audit event" do
        described_class.cancel(job_class, job_id)

        expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
          "job.cancelled",
          workflow_id: workflow_id,
          job_class: job_class.name,
          job_id: job_id,
          status: "requested"
        )
      end

      context "when the workflow uses a custom workflow ID" do
        let(:custom_workflow_id) { "tenant-42:ajwf:#{job_class.name}:#{job_id}" }
        let(:workflow_info) { double("WorkflowInfo", id: custom_workflow_id) }

        before do
          allow(client).to receive(:workflow_handle).with(custom_workflow_id).and_return(handle)
        end

        it "cancels the workflow returned by Temporal search" do
          described_class.cancel(job_class, job_id)

          expect(client).to have_received(:workflow_handle).with(custom_workflow_id)
          expect(handle).to have_received(:cancel)
        end
      end
    end

    context "when the workflow is already completed" do
      let(:workflow_info) { double("WorkflowInfo") }

      before do
        # Not found in running workflows
        allow(client).to receive(:list_workflows)
          .with(running_query)
          .and_return([])
        # Found in closed workflows
        allow(client).to receive(:list_workflows)
          .with(closed_query)
          .and_return([workflow_info])
      end

      it "returns false and does not attempt to cancel" do
        result = described_class.cancel(job_class, job_id)

        expect(result).to eq(false)
        expect(handle).not_to have_received(:cancel)
      end

      it "logs a warning that the workflow is already completed" do
        described_class.cancel(job_class, job_id)

        expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
          "cancellation_workflow_already_completed",
          workflow_id: workflow_id,
          job_class: job_class.name,
          job_id: job_id,
          status: "completed"
        )
      end
    end

    context "when the workflow never existed" do
      before do
        # Not found in running workflows
        allow(client).to receive(:list_workflows)
          .with(running_query)
          .and_return([])
        # Not found in closed workflows
        allow(client).to receive(:list_workflows)
          .with(closed_query)
          .and_return([])
      end

      it "raises WorkflowNotFoundError" do
        expect { described_class.cancel(job_class, job_id) }
          .to raise_error(ActiveJob::Temporal::WorkflowNotFoundError, /No workflow found for job_id #{job_id}/)
      end

      it "does not cancel a workflow from another job class with the same job ID" do
        other_workflow_id = "ajwf:ScheduledJob:#{job_id}"
        other_workflow_info = double("WorkflowInfo", id: other_workflow_id)
        broad_running_query = "ajJobId='#{job_id}' AND ExecutionStatus='Running'"

        allow(client).to receive(:list_workflows)
          .with(broad_running_query)
          .and_return([other_workflow_info])
        allow(client).to receive(:workflow_handle).with(other_workflow_id).and_return(handle)

        expect { described_class.cancel(job_class, job_id) }
          .to raise_error(ActiveJob::Temporal::WorkflowNotFoundError)
        expect(client).not_to have_received(:workflow_handle).with(other_workflow_id)
      end
    end

    context "when Temporal connection fails" do
      let(:connection_error) { StandardError.new("Connection refused") }

      before do
        allow(client).to receive(:list_workflows)
          .with(running_query)
          .and_raise(connection_error)
      end

      it "raises TemporalConnectionError" do
        expect { described_class.cancel(job_class, job_id) }
          .to raise_error(ActiveJob::Temporal::TemporalConnectionError,
                          /Failed to query Temporal workflows for job_id #{job_id}/)
      end
    end

    context "job_id validation (security)" do
      context "when job_id contains SQL injection attempt" do
        let(:malicious_job_id) { "test' OR '1'='1" }

        it "raises ArgumentError before making any queries" do
          expect { described_class.cancel(job_class, malicious_job_id) }
            .to raise_error(ArgumentError, /Invalid job_id format/)

          # Verify no queries were made
          expect(client).not_to have_received(:list_workflows)
        end
      end

      context "when job_id contains single quotes" do
        let(:malicious_job_id) { "test'123" }

        it "raises ArgumentError" do
          expect { described_class.cancel(job_class, malicious_job_id) }
            .to raise_error(ArgumentError, /Invalid job_id format/)
        end
      end

      context "when job_id is not a valid UUID format" do
        let(:invalid_job_id) { "not-a-uuid" }

        it "raises ArgumentError with helpful message" do
          expect { described_class.cancel(job_class, invalid_job_id) }
            .to raise_error(ArgumentError, /Invalid job_id format: expected UUID/)
        end
      end

      context "when job_id is nil" do
        let(:nil_job_id) { nil }

        it "raises ArgumentError" do
          expect { described_class.cancel(job_class, nil_job_id) }
            .to raise_error(ArgumentError, /Invalid job_id format/)
        end
      end

      context "when job_id is an integer" do
        let(:integer_job_id) { 12_345 }

        it "raises ArgumentError" do
          expect { described_class.cancel(job_class, integer_job_id) }
            .to raise_error(ArgumentError, /Invalid job_id format/)
        end
      end

      context "when job_id is a valid UUID (lowercase)" do
        let(:valid_uuid) { "550e8400-e29b-41d4-a716-446655440000" }
        let(:workflow_info) { double("WorkflowInfo") }

        before do
          allow(client).to receive(:list_workflows)
            .with("ajClass='#{job_class.name}' AND ajJobId='#{valid_uuid}' AND ExecutionStatus='Running'")
            .and_return([workflow_info])
        end

        it "accepts the UUID and proceeds with cancellation" do
          expect { described_class.cancel(job_class, valid_uuid) }.not_to raise_error
        end
      end

      context "when job_id is a valid UUID (uppercase)" do
        let(:valid_uuid_uppercase) { "550E8400-E29B-41D4-A716-446655440000" }
        let(:workflow_info) { double("WorkflowInfo") }
        let(:workflow_id_uppercase) { "ajwf:#{job_class.name}:#{valid_uuid_uppercase}" }

        before do
          allow(client).to receive(:list_workflows)
            .with("ajClass='#{job_class.name}' AND ajJobId='#{valid_uuid_uppercase}' AND ExecutionStatus='Running'")
            .and_return([workflow_info])
          allow(client).to receive(:workflow_handle).with(workflow_id_uppercase).and_return(handle)
        end

        it "accepts the UUID and proceeds with cancellation" do
          expect { described_class.cancel(job_class, valid_uuid_uppercase) }.not_to raise_error
        end
      end

      context "when job_id is a valid UUID (mixed case)" do
        let(:valid_uuid_mixed) { "550e8400-E29B-41d4-A716-446655440000" }
        let(:workflow_info) { double("WorkflowInfo") }
        let(:workflow_id_mixed) { "ajwf:#{job_class.name}:#{valid_uuid_mixed}" }

        before do
          allow(client).to receive(:list_workflows)
            .with("ajClass='#{job_class.name}' AND ajJobId='#{valid_uuid_mixed}' AND ExecutionStatus='Running'")
            .and_return([workflow_info])
          allow(client).to receive(:workflow_handle).with(workflow_id_mixed).and_return(handle)
        end

        it "accepts the UUID and proceeds with cancellation" do
          expect { described_class.cancel(job_class, valid_uuid_mixed) }.not_to raise_error
        end
      end
    end
  end

  describe ".cancel_all" do
    let(:job_class) { SimpleJob }

    it "delegates to cancel_where with the job class search attribute" do
      summary = { terminated: 1, failed: 0, errors: [] }

      allow(described_class).to receive(:cancel_where).and_return(summary)

      result = described_class.cancel_all(job_class)

      expect(result).to eq(summary)
      expect(described_class).to have_received(:cancel_where).with(ajClass: job_class.name)
    end

    it "terminates running workflows matching the job class" do
      temporal_client_class = Class.new do
        def workflow_handle(_workflow_id, run_id: nil); end
        def list_workflow_page(_query = nil, page_size: nil, next_page_token: nil); end
      end
      workflow_handle_class = Class.new do
        def terminate(_reason = nil); end
      end
      page_class = Struct.new(:executions, :next_page_token)
      client = instance_double(temporal_client_class)
      handle = instance_double(workflow_handle_class)
      workflow_execution = double("WorkflowExecution", id: "workflow-1", run_id: "run-1")
      query = "ajClass='#{job_class.name}' AND ExecutionStatus='Running'"

      allow(ActiveJob::Temporal).to receive(:client).and_return(client)
      allow(client).to receive(:list_workflow_page)
        .with(query, page_size: 100, next_page_token: nil)
        .and_return(page_class.new([workflow_execution], nil))
      allow(client).to receive(:workflow_handle).with("workflow-1", run_id: "run-1").and_return(handle)
      allow(handle).to receive(:terminate)

      result = described_class.cancel_all(job_class)

      expect(result).to eq(terminated: 1, failed: 0, errors: [])
      expect(handle).to have_received(:terminate).with("ActiveJob::Temporal.cancel_where")
    end

    it "rejects unnamed job classes" do
      unnamed_class = Class.new

      expect { described_class.cancel_all(unnamed_class) }
        .to raise_error(ArgumentError, /job_class must be a named class/)
    end
  end

  describe ".cancel_where" do
    let(:temporal_client_class) do
      Class.new do
        def workflow_handle(_workflow_id, run_id: nil); end
        def list_workflow_page(_query = nil, page_size: nil, next_page_token: nil); end
      end
    end
    let(:workflow_handle_class) do
      Class.new do
        def terminate(_reason = nil); end
      end
    end
    let(:page_class) { Struct.new(:executions, :next_page_token) }
    let(:client) { instance_double(temporal_client_class) }
    let(:handle) { instance_double(workflow_handle_class) }

    before do
      allow(ActiveJob::Temporal).to receive(:client).and_return(client)
      allow(handle).to receive(:terminate)
      allow(ActiveJob::Temporal::AuditLog).to receive(:record)
    end

    it "terminates running workflows matching job class" do
      workflow_execution = double("WorkflowExecution", id: "workflow-1", run_id: "run-1")
      query = "ajClass='#{SimpleJob.name}' AND ExecutionStatus='Running'"

      allow(client).to receive(:list_workflow_page)
        .with(query, page_size: 100, next_page_token: nil)
        .and_return(page_class.new([workflow_execution], nil))
      allow(client).to receive(:workflow_handle).with("workflow-1", run_id: "run-1").and_return(handle)

      result = described_class.cancel_where(ajClass: SimpleJob.name)

      expect(result).to eq(terminated: 1, failed: 0, errors: [])
      expect(handle).to have_received(:terminate).with("ActiveJob::Temporal.cancel_where")
      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.cancelled",
        workflow_id: "workflow-1",
        run_id: "run-1",
        status: "terminated",
        reason: "ActiveJob::Temporal.cancel_where"
      )
    end

    it "supports queue and tenant search attributes" do
      query = "ajQueue='low_priority' AND ajTenantId=123 AND ExecutionStatus='Running'"

      allow(client).to receive(:list_workflow_page)
        .with(query, page_size: 100, next_page_token: nil)
        .and_return(page_class.new([], nil))

      result = described_class.cancel_where(ajQueue: "low_priority", ajTenantId: 123)

      expect(result).to eq(terminated: 0, failed: 0, errors: [])
    end

    it "handles paginated workflow results" do
      first_workflow = double("WorkflowExecution", id: "workflow-1", run_id: "run-1")
      second_workflow = double("WorkflowExecution", id: "workflow-2", run_id: "run-2")
      query = "ajQueue='bulk' AND ExecutionStatus='Running'"
      first_handle = instance_double(workflow_handle_class)
      second_handle = instance_double(workflow_handle_class)

      allow(first_handle).to receive(:terminate)
      allow(second_handle).to receive(:terminate)
      allow(client).to receive(:list_workflow_page)
        .with(query, page_size: 100, next_page_token: nil)
        .and_return(page_class.new([first_workflow], "next-page"))
      allow(client).to receive(:list_workflow_page)
        .with(query, page_size: 100, next_page_token: "next-page")
        .and_return(page_class.new([second_workflow], nil))
      allow(client).to receive(:workflow_handle).with("workflow-1", run_id: "run-1").and_return(first_handle)
      allow(client).to receive(:workflow_handle).with("workflow-2", run_id: "run-2").and_return(second_handle)

      result = described_class.cancel_where(ajQueue: "bulk")

      expect(result).to eq(terminated: 2, failed: 0, errors: [])
      expect(first_handle).to have_received(:terminate)
      expect(second_handle).to have_received(:terminate)
    end

    it "records per-workflow termination failures" do
      successful_workflow = double("WorkflowExecution", id: "workflow-1", run_id: "run-1")
      failing_workflow = double("WorkflowExecution", id: "workflow-2", run_id: "run-2")
      query = "ajQueue='bulk' AND ExecutionStatus='Running'"
      successful_handle = instance_double(workflow_handle_class)
      failing_handle = instance_double(workflow_handle_class)

      allow(successful_handle).to receive(:terminate)
      allow(failing_handle).to receive(:terminate).and_raise(StandardError, "permission denied")
      allow(client).to receive(:list_workflow_page)
        .with(query, page_size: 100, next_page_token: nil)
        .and_return(page_class.new([successful_workflow, failing_workflow], nil))
      allow(client).to receive(:workflow_handle).with("workflow-1", run_id: "run-1").and_return(successful_handle)
      allow(client).to receive(:workflow_handle).with("workflow-2", run_id: "run-2").and_return(failing_handle)

      result = described_class.cancel_where(ajQueue: "bulk")

      expect(result).to eq(
        terminated: 1,
        failed: 1,
        errors: [
          {
            workflow_id: "workflow-2",
            run_id: "run-2",
            error: "StandardError: permission denied"
          }
        ]
      )
    end

    it "escapes string search attribute values" do
      query = "ajQueue='vip''queue' AND ExecutionStatus='Running'"

      allow(client).to receive(:list_workflow_page)
        .with(query, page_size: 100, next_page_token: nil)
        .and_return(page_class.new([], nil))

      described_class.cancel_where(ajQueue: "vip'queue")

      expect(client).to have_received(:list_workflow_page)
        .with(query, page_size: 100, next_page_token: nil)
    end

    it "rejects unsupported search attributes before querying Temporal" do
      allow(client).to receive(:list_workflow_page)

      expect { described_class.cancel_where(customAttribute: "value") }
        .to raise_error(ArgumentError, /Unsupported search attribute/)

      expect(client).not_to have_received(:list_workflow_page)
    end

    it "rejects empty filters" do
      expect { described_class.cancel_where({}) }
        .to raise_error(ArgumentError, /requires at least one search attribute/)
    end

    it "wraps list failures in TemporalConnectionError" do
      query = "ajQueue='bulk' AND ExecutionStatus='Running'"

      allow(client).to receive(:list_workflow_page)
        .with(query, page_size: 100, next_page_token: nil)
        .and_raise(StandardError, "connection refused")

      expect { described_class.cancel_where(ajQueue: "bulk") }
        .to raise_error(ActiveJob::Temporal::TemporalConnectionError, /batch cancellation: connection refused/)
    end
  end
end

RSpec.describe ActiveJob::Temporal do
  describe ".cancel_all" do
    it "delegates to the cancellation module" do
      summary = { terminated: 1, failed: 0, errors: [] }

      allow(ActiveJob::Temporal::Cancel).to receive(:cancel_all).with(SimpleJob).and_return(summary)

      expect(described_class.cancel_all(SimpleJob)).to eq(summary)
    end
  end

  describe ".cancel_where" do
    it "delegates to the cancellation module" do
      filters = { ajQueue: "default" }
      summary = { terminated: 1, failed: 0, errors: [] }

      allow(ActiveJob::Temporal::Cancel).to receive(:cancel_where).with(filters).and_return(summary)

      expect(described_class.cancel_where(filters)).to eq(summary)
    end
  end
end
