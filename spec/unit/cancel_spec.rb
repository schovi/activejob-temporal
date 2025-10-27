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
      allow(handle).to receive(:cancel)
      allow(ActiveJob::Temporal::Logger).to receive(:log_event)
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
    end

    it "cancels the workflow via Temporal client" do
      described_class.cancel(job_class, job_id)

      expect(client).to have_received(:workflow_handle).with(workflow_id)
      expect(handle).to have_received(:cancel)
    end

    it "logs a cancellation request event" do
      described_class.cancel(job_class, job_id)

      expect(ActiveJob::Temporal::Logger).to have_received(:log_event).with(
        "cancellation_requested",
        workflow_id: workflow_id,
        job_class: job_class.name,
        job_id: job_id
      )
    end

    context "when the workflow is not found" do
      let(:error) do
        Temporalio::Error::RPCError.new(
          "workflow not found",
          code: Temporalio::Error::RPCError::Code::NOT_FOUND,
          raw_grpc_status: nil
        )
      end

      before do
        allow(handle).to receive(:cancel).and_raise(error)
      end

      it "logs a warning and suppresses the error" do
        expect { described_class.cancel(job_class, job_id) }.not_to raise_error

        expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
          "cancellation_workflow_not_found",
          workflow_id: workflow_id,
          job_class: job_class.name,
          job_id: job_id,
          error: error.message
        )
        expect(ActiveJob::Temporal::Logger).not_to have_received(:log_event)
      end
    end

    context "when a different RPC error occurs" do
      let(:error) do
        Temporalio::Error::RPCError.new(
          "permission denied",
          code: Temporalio::Error::RPCError::Code::PERMISSION_DENIED,
          raw_grpc_status: nil
        )
      end

      before do
        allow(handle).to receive(:cancel).and_raise(error)
      end

      it "re-raises the error" do
        expect { described_class.cancel(job_class, job_id) }.to raise_error(error)
      end
    end

    context "when the Temporal RPC error class is unavailable" do
      before do
        hide_const("Temporalio::Error::RPCError")
        allow(handle).to receive(:cancel).and_raise(StandardError.new("generic failure"))
      end

      it "re-raises the error" do
        expect { described_class.cancel(job_class, job_id) }.to raise_error(StandardError, "generic failure")
      end
    end

    context "when the RPC error omits the NOT_FOUND constant" do
      let(:error) { Temporalio::Error::RPCError.new("workflow missing", code: 5, raw_grpc_status: nil) }

      before do
        hide_const("Temporalio::Error::RPCError::Code::NOT_FOUND")
        allow(handle).to receive(:cancel).and_raise(error)
      end

      it "falls back to the numeric code and suppresses the error" do
        expect { described_class.cancel(job_class, job_id) }.not_to raise_error

        expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
          "cancellation_workflow_not_found",
          workflow_id: workflow_id,
          job_class: job_class.name,
          job_id: job_id,
          error: error.message
        )
      end
    end

    context "when the RPC error lacks a code accessor" do
      let(:rpc_error_class) do
        Class.new(StandardError) do
          def self.name
            "Temporalio::Error::RPCError"
          end

          def initialize(message = "rpc error", code: nil, _raw_grpc_status: nil)
            super(message)
            @code = code
          end
        end
      end

      before do
        stub_const("Temporalio::Error::RPCError", rpc_error_class)
        allow(handle).to receive(:cancel).and_raise(rpc_error_class.new("missing code"))
      end

      it "re-raises the error" do
        expect { described_class.cancel(job_class, job_id) }.to raise_error(rpc_error_class, "missing code")
      end
    end

    context "when a non-RPC error bubbles up" do
      before do
        allow(handle).to receive(:cancel).and_raise(StandardError.new("other error"))
      end

      it "re-raises the error" do
        expect { described_class.cancel(job_class, job_id) }.to raise_error(StandardError, "other error")
      end
    end
  end
end
