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
    end

    context "when the workflow is running" do
      let(:workflow_info) { double("WorkflowInfo") }

      before do
        # Mock running workflow
        allow(client).to receive(:list_workflows)
          .with("ajJobId='#{job_id}' AND ExecutionStatus='Running'")
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
    end

    context "when the workflow is already completed" do
      let(:workflow_info) { double("WorkflowInfo") }

      before do
        # Not found in running workflows
        allow(client).to receive(:list_workflows)
          .with("ajJobId='#{job_id}' AND ExecutionStatus='Running'")
          .and_return([])
        # Found in closed workflows
        allow(client).to receive(:list_workflows)
          .with("ajJobId='#{job_id}' AND ExecutionStatus IN ('Completed', 'Failed', 'Cancelled', " \
                "'Terminated', 'TimedOut', 'ContinuedAsNew')")
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
          .with("ajJobId='#{job_id}' AND ExecutionStatus='Running'")
          .and_return([])
        # Not found in closed workflows
        allow(client).to receive(:list_workflows)
          .with("ajJobId='#{job_id}' AND ExecutionStatus IN ('Completed', 'Failed', 'Cancelled', " \
                "'Terminated', 'TimedOut', 'ContinuedAsNew')")
          .and_return([])
      end

      it "raises WorkflowNotFoundError" do
        expect { described_class.cancel(job_class, job_id) }
          .to raise_error(ActiveJob::Temporal::WorkflowNotFoundError, /No workflow found for job_id #{job_id}/)
      end
    end

    context "when Temporal connection fails" do
      let(:connection_error) { StandardError.new("Connection refused") }

      before do
        allow(client).to receive(:list_workflows)
          .with("ajJobId='#{job_id}' AND ExecutionStatus='Running'")
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
            .with("ajJobId='#{valid_uuid}' AND ExecutionStatus='Running'")
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
            .with("ajJobId='#{valid_uuid_uppercase}' AND ExecutionStatus='Running'")
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
            .with("ajJobId='#{valid_uuid_mixed}' AND ExecutionStatus='Running'")
            .and_return([workflow_info])
          allow(client).to receive(:workflow_handle).with(workflow_id_mixed).and_return(handle)
        end

        it "accepts the UUID and proceeds with cancellation" do
          expect { described_class.cancel(job_class, valid_uuid_mixed) }.not_to raise_error
        end
      end
    end
  end
end
