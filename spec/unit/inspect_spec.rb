# frozen_string_literal: true

require "spec_helper"
require_relative "../fixtures/sample_jobs"

RSpec.describe ActiveJob::Temporal::Inspect do
  let(:job_class) { SimpleJob }
  let(:job_id) { "550e8400-e29b-41d4-a716-446655440000" }
  let(:workflow_id) { "ajwf:#{job_class.name}:#{job_id}" }
  let(:run_id) { "run-1" }
  let(:query) { "ajClass='#{job_class.name}' AND ajJobId='#{job_id}'" }
  let(:started_at) { Time.utc(2026, 5, 20, 13, 0, 0) }
  let(:closed_at) { nil }
  let(:temporal_client_class) do
    Class.new do
      def workflow_handle(_workflow_id, run_id: nil); end
      def list_workflows(_query = nil); end
    end
  end
  let(:workflow_handle_class) do
    Class.new do
      def describe; end
    end
  end
  let(:client) { instance_double(temporal_client_class) }
  let(:handle) { instance_double(workflow_handle_class) }
  let(:workflow_execution) { double("WorkflowExecution", id: workflow_id, run_id: run_id) }
  let(:not_found_error) do
    Temporalio::Error::RPCError.new(
      "not found",
      code: Temporalio::Error::RPCError::Code::NOT_FOUND,
      raw_grpc_status: nil
    )
  end
  let(:raw_description) { double("RawDescription", pending_activities: []) }
  let(:description) do
    double(
      "WorkflowDescription",
      id: workflow_id,
      run_id: run_id,
      status: Temporalio::Client::WorkflowExecutionStatus::RUNNING,
      start_time: started_at,
      close_time: closed_at,
      raw_description: raw_description
    )
  end

  before do
    allow(ActiveJob::Temporal).to receive(:client).and_return(client)
    allow(client).to receive(:list_workflows).with(query).and_return([workflow_execution])
    allow(client).to receive(:workflow_handle).with(workflow_id, run_id: nil).and_return(handle)
    allow(handle).to receive(:describe).and_return(description)
  end

  describe ".status" do
    it "returns workflow status from Temporal describe" do
      result = described_class.status(job_class, job_id)

      expect(result).to eq(
        state: :running,
        workflow_id: workflow_id,
        run_id: run_id,
        started_at: started_at,
        closed_at: nil,
        attempt: nil,
        last_failure: nil
      )
    end

    it "uses the workflow ID discovered by search attributes" do
      custom_workflow_id = "tenant-42:ajwf:#{job_class.name}:#{job_id}"
      custom_execution = double("WorkflowExecution", id: custom_workflow_id, run_id: run_id)
      custom_handle = instance_double(workflow_handle_class)

      allow(handle).to receive(:describe).and_raise(not_found_error)
      allow(client).to receive(:list_workflows).with(query).and_return([custom_execution])
      allow(client).to receive(:workflow_handle).with(custom_workflow_id, run_id: run_id).and_return(custom_handle)
      allow(custom_handle).to receive(:describe).and_return(description)

      described_class.status(job_class, job_id)

      expect(client).to have_received(:workflow_handle).with(custom_workflow_id, run_id: run_id)
    end

    it "escapes job class names when searching fallback workflows" do
      dynamic_job_class = Class.new(ActiveJob::Base)
      safe_name = "SimpleJob"
      unsafe_name = "SimpleJob' OR '1'='1"
      escaped_query = "ajClass='SimpleJob'' OR ''1''=''1' AND ajJobId='#{job_id}'"
      custom_workflow_id = "tenant-42:ajwf:#{safe_name}:#{job_id}"
      custom_execution = double("WorkflowExecution", id: custom_workflow_id, run_id: run_id)
      custom_handle = instance_double(workflow_handle_class)

      allow(dynamic_job_class).to receive(:name).and_return(safe_name, safe_name, safe_name, unsafe_name)
      allow(client).to receive(:workflow_handle).with("ajwf:#{safe_name}:#{job_id}", run_id: nil).and_return(handle)
      allow(handle).to receive(:describe).and_raise(not_found_error)
      allow(client).to receive(:list_workflows).with(escaped_query).and_return([custom_execution])
      allow(client).to receive(:workflow_handle).with(custom_workflow_id, run_id: run_id).and_return(custom_handle)
      allow(custom_handle).to receive(:describe).and_return(description)

      described_class.status(dynamic_job_class, job_id)

      expect(client).to have_received(:list_workflows).with(escaped_query)
    end

    it "uses the default workflow ID before querying search attributes" do
      result = described_class.status(job_class, job_id)

      expect(result[:workflow_id]).to eq(workflow_id)
      expect(client).to have_received(:workflow_handle).with(workflow_id, run_id: nil)
      expect(client).not_to have_received(:list_workflows)
    end

    it "returns nil when the workflow does not exist" do
      allow(client).to receive(:list_workflows).with(query).and_return([])
      allow(handle).to receive(:describe).and_raise(not_found_error)

      expect(described_class.status(job_class, job_id)).to be_nil
    end

    it "returns nil when search attributes are unavailable and the default workflow ID is missing" do
      invalid_argument_error = Temporalio::Error::RPCError.new(
        "invalid search attribute",
        code: Temporalio::Error::RPCError::Code::INVALID_ARGUMENT,
        raw_grpc_status: nil
      )

      allow(client).to receive(:list_workflows).with(query).and_raise(invalid_argument_error)
      allow(handle).to receive(:describe).and_raise(not_found_error)

      expect(described_class.status(job_class, job_id)).to be_nil
    end

    it "maps completed workflow status" do
      completed_description = double(
        "WorkflowDescription",
        id: workflow_id,
        run_id: run_id,
        status: Temporalio::Client::WorkflowExecutionStatus::COMPLETED,
        start_time: started_at,
        close_time: Time.utc(2026, 5, 20, 13, 1, 0),
        raw_description: raw_description
      )

      allow(handle).to receive(:describe).and_return(completed_description)

      expect(described_class.status(job_class, job_id)[:state]).to eq(:completed)
    end

    it "includes pending activity attempt and failure details when available" do
      failure_info = double("ApplicationFailureInfo", type: "NetworkError")
      failure = double("Failure", application_failure_info: failure_info, message: "timeout")
      pending_activity = double("PendingActivity", attempt: 2, last_failure: failure)
      raw_description = double("RawDescription", pending_activities: [pending_activity])

      allow(description).to receive(:raw_description).and_return(raw_description)

      result = described_class.status(job_class, job_id)

      expect(result[:attempt]).to eq(2)
      expect(result[:last_failure]).to eq("NetworkError: timeout")
    end

    it "raises ArgumentError for invalid job IDs before querying Temporal" do
      expect { described_class.status(job_class, "bad-id") }
        .to raise_error(ArgumentError, /Invalid job_id format/)

      expect(client).not_to have_received(:list_workflows)
    end

    it "raises ArgumentError for non-class job_class values before querying Temporal" do
      fake_class = double("JobClass", name: "FakeJob")

      expect { described_class.status(fake_class, job_id) }
        .to raise_error(ArgumentError, /job_class must be a named class/)

      expect(client).not_to have_received(:list_workflows)
    end

    it "raises ArgumentError for unsafe job class names before querying Temporal" do
      unsafe_class = Class.new

      allow(unsafe_class).to receive(:name).and_return("Unsafe'Job")

      expect { described_class.status(unsafe_class, job_id) }
        .to raise_error(ArgumentError, /valid constant name/)

      expect(client).not_to have_received(:list_workflows)
    end

    it "wraps Temporal connection failures" do
      allow(handle).to receive(:describe).and_raise(StandardError, "connection refused")

      expect { described_class.status(job_class, job_id) }
        .to raise_error(ActiveJob::Temporal::TemporalConnectionError, /Failed to inspect Temporal workflow/)
    end
  end

  describe "predicate methods" do
    it "reports running workflows" do
      expect(described_class.running?(job_class, job_id)).to be(true)
      expect(described_class.completed?(job_class, job_id)).to be(false)
      expect(described_class.failed?(job_class, job_id)).to be(false)
    end

    it "reports completed workflows" do
      allow(described_class).to receive(:status).with(job_class, job_id).and_return(state: :completed)

      expect(described_class.running?(job_class, job_id)).to be(false)
      expect(described_class.completed?(job_class, job_id)).to be(true)
      expect(described_class.failed?(job_class, job_id)).to be(false)
    end

    it "returns false when the workflow is missing" do
      allow(described_class).to receive(:status).with(job_class, job_id).and_return(nil)

      expect(described_class.running?(job_class, job_id)).to be(false)
      expect(described_class.completed?(job_class, job_id)).to be(false)
      expect(described_class.failed?(job_class, job_id)).to be(false)
    end
  end
end

RSpec.describe ActiveJob::Temporal do
  let(:job_id) { "550e8400-e29b-41d4-a716-446655440000" }

  describe ".status" do
    it "delegates to the inspection module" do
      status = { state: :running }

      allow(ActiveJob::Temporal::Inspect).to receive(:status).with(SimpleJob, job_id).and_return(status)

      expect(described_class.status(SimpleJob, job_id)).to eq(status)
    end
  end

  describe ".running?" do
    it "delegates to the inspection module" do
      allow(ActiveJob::Temporal::Inspect).to receive(:running?).with(SimpleJob, job_id).and_return(true)

      expect(described_class.running?(SimpleJob, job_id)).to be(true)
    end
  end

  describe ".completed?" do
    it "delegates to the inspection module" do
      allow(ActiveJob::Temporal::Inspect).to receive(:completed?).with(SimpleJob, job_id).and_return(true)

      expect(described_class.completed?(SimpleJob, job_id)).to be(true)
    end
  end

  describe ".failed?" do
    it "delegates to the inspection module" do
      allow(ActiveJob::Temporal::Inspect).to receive(:failed?).with(SimpleJob, job_id).and_return(true)

      expect(described_class.failed?(SimpleJob, job_id)).to be(true)
    end
  end
end
