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
    let(:job_id) { "test-job-123" }
    let(:workflow_id) { "ajwf:#{job_class.name}:#{job_id}" }
    let(:temporal_client_class) do
      Class.new do
        def workflow_handle(_workflow_id); end
        def list_workflows(query:); end
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
          .with(query: "ajJobId='#{job_id}' AND ExecutionStatus='Running'")
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
          .with(query: "ajJobId='#{job_id}' AND ExecutionStatus='Running'")
          .and_return([])
        # Found in closed workflows
        allow(client).to receive(:list_workflows)
          .with(query: "ajJobId='#{job_id}' AND ExecutionStatus IN ('Completed', 'Failed', 'Cancelled', " \
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
          .with(query: "ajJobId='#{job_id}' AND ExecutionStatus='Running'")
          .and_return([])
        # Not found in closed workflows
        allow(client).to receive(:list_workflows)
          .with(query: "ajJobId='#{job_id}' AND ExecutionStatus IN ('Completed', 'Failed', 'Cancelled', " \
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
          .with(query: "ajJobId='#{job_id}' AND ExecutionStatus='Running'")
          .and_raise(connection_error)
      end

      it "raises TemporalConnectionError" do
        expect { described_class.cancel(job_class, job_id) }
          .to raise_error(ActiveJob::Temporal::TemporalConnectionError,
                          /Failed to query Temporal workflows for job_id #{job_id}/)
      end
    end
  end
end
