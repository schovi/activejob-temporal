# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::SignalQuery do
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
  let(:client_class) do
    Class.new do
      def workflow_handle(_workflow_id, run_id: nil); end
      def list_workflows(_query); end
    end
  end
  let(:handle_class) do
    Class.new do
      def signal(_name, *_args); end
      def query(_name, *_args); end
      def execute_update(_name, *_args); end
    end
  end
  let(:client) { instance_double(client_class) }
  let(:default_handle) { instance_double(handle_class) }
  let(:custom_handle) { instance_double(handle_class) }
  let(:workflow_execution) { double("WorkflowExecution", id: custom_workflow_id, run_id: run_id) }
  let(:not_found_error) do
    Temporalio::Error::RPCError.new(
      "not found",
      code: Temporalio::Error::RPCError::Code::NOT_FOUND,
      raw_grpc_status: nil
    )
  end

  before do
    allow(ActiveJob::Temporal).to receive(:client).and_return(client)
    allow(client).to receive(:workflow_handle).with(default_workflow_id, run_id: nil).and_return(default_handle)
    allow(client).to receive(:workflow_handle).with(custom_workflow_id, run_id: run_id).and_return(custom_handle)
    allow(client).to receive(:list_workflows).with(search_query).and_return([workflow_execution])
    allow(default_handle).to receive(:signal)
    allow(default_handle).to receive(:query).and_return("default-result")
    allow(default_handle).to receive(:execute_update).and_return("default-update-result")
    allow(custom_handle).to receive(:signal)
    allow(custom_handle).to receive(:query).and_return("custom-result")
    allow(custom_handle).to receive(:execute_update).and_return("custom-update-result")
  end

  describe ".signal" do
    it "sends signals to the default workflow handle before searching" do
      described_class.signal(job_class, job_id, :pause, "manual hold")

      expect(default_handle).to have_received(:signal).with("pause", "manual hold")
      expect(client).not_to have_received(:list_workflows)
    end

    it "falls back to the running workflow found by job search attributes" do
      allow(default_handle).to receive(:signal).and_raise(not_found_error)

      described_class.signal(job_class, job_id, :pause, "manual hold")

      expect(client).to have_received(:list_workflows).with(search_query)
      expect(custom_handle).to have_received(:signal).with("pause", "manual hold")
    end

    it "escapes job class names when searching fallback workflows" do
      dynamic_job_class = Class.new(ActiveJob::Base)
      safe_name = "SignalQueryJob"
      unsafe_name = "SignalQueryJob' OR '1'='1"
      escaped_query = "ajClass='SignalQueryJob'' OR ''1''=''1' AND ajJobId='#{job_id}' " \
                      "AND ExecutionStatus='Running'"

      allow(dynamic_job_class).to receive(:name).and_return(safe_name, safe_name, safe_name, unsafe_name)
      allow(client).to receive(:workflow_handle)
        .with("ajwf:#{safe_name}:#{job_id}", run_id: nil)
        .and_return(default_handle)
      allow(default_handle).to receive(:signal).and_raise(not_found_error)
      allow(client).to receive(:list_workflows).with(escaped_query).and_return([workflow_execution])

      described_class.signal(dynamic_job_class, job_id, :pause)

      expect(client).to have_received(:list_workflows).with(escaped_query)
      expect(custom_handle).to have_received(:signal).with("pause")
    end

    it "raises WorkflowNotFoundError when no running workflow is found" do
      allow(default_handle).to receive(:signal).and_raise(not_found_error)
      allow(client).to receive(:list_workflows).with(search_query).and_return([])

      expect { described_class.signal(job_class, job_id, :pause) }
        .to raise_error(ActiveJob::Temporal::WorkflowNotFoundError, /No running workflow/)
    end

    it "does not wrap non-RPC default handle failures as connection errors" do
      signal_error = RuntimeError.new("signal handler failed")

      allow(default_handle).to receive(:signal).and_raise(signal_error)

      expect { described_class.signal(job_class, job_id, :pause) }
        .to raise_error(signal_error)
      expect(client).not_to have_received(:list_workflows)
    end

    it "validates arguments before contacting Temporal" do
      expect { described_class.signal(job_class, "not-a-uuid", :pause) }
        .to raise_error(ArgumentError, /Invalid job_id format/)
      expect { described_class.signal("SignalQueryJob", job_id, :pause) }
        .to raise_error(ArgumentError, /job_class must be a named class/)
      expect { described_class.signal(job_class, job_id, "invalid-name") }
        .to raise_error(ArgumentError, /signal names/)

      expect(client).not_to have_received(:workflow_handle)
    end
  end

  describe ".query" do
    it "queries the default workflow handle before searching" do
      result = described_class.query(job_class, job_id, :state)

      expect(result).to eq("default-result")
      expect(default_handle).to have_received(:query).with("state")
      expect(client).not_to have_received(:list_workflows)
    end

    it "falls back to the running workflow found by job search attributes" do
      allow(default_handle).to receive(:query).and_raise(not_found_error)

      result = described_class.query(job_class, job_id, :state)

      expect(result).to eq("custom-result")
      expect(client).to have_received(:list_workflows).with(search_query)
      expect(custom_handle).to have_received(:query).with("state")
    end

    it "forwards an explicit query reject condition" do
      described_class.query(job_class, job_id, :state, reject_condition: :not_open)

      expect(default_handle).to have_received(:query).with("state", reject_condition: :not_open)
    end

    it "raises workflow query failures without wrapping them as connection errors" do
      query_error = Temporalio::Error::WorkflowQueryFailedError.new("query failed")

      allow(default_handle).to receive(:query).and_raise(query_error)

      expect { described_class.query(job_class, job_id, :state) }
        .to raise_error(query_error)
    end

    it "does not wrap non-RPC default handle failures as connection errors" do
      query_error = RuntimeError.new("query handler failed")

      allow(default_handle).to receive(:query).and_raise(query_error)

      expect { described_class.query(job_class, job_id, :state) }
        .to raise_error(query_error)
      expect(client).not_to have_received(:list_workflows)
    end

    it "raises WorkflowNotFoundError when no running workflow is found" do
      allow(default_handle).to receive(:query).and_raise(not_found_error)
      allow(client).to receive(:list_workflows).with(search_query).and_return([])

      expect { described_class.query(job_class, job_id, :state) }
        .to raise_error(ActiveJob::Temporal::WorkflowNotFoundError, /No running workflow/)
    end
  end

  describe ".update" do
    it "executes updates on the default workflow handle before searching" do
      result = described_class.update(job_class, job_id, :set_progress, 75)

      expect(result).to eq("default-update-result")
      expect(default_handle).to have_received(:execute_update).with("set_progress", 75)
      expect(client).not_to have_received(:list_workflows)
    end

    it "falls back to the running workflow found by job search attributes" do
      allow(default_handle).to receive(:execute_update).and_raise(not_found_error)

      result = described_class.update(job_class, job_id, :set_progress, 75)

      expect(result).to eq("custom-update-result")
      expect(client).to have_received(:list_workflows).with(search_query)
      expect(custom_handle).to have_received(:execute_update).with("set_progress", 75)
    end

    it "raises workflow update failures without wrapping them as connection errors" do
      update_error = Temporalio::Error::WorkflowUpdateFailedError.new

      allow(default_handle).to receive(:execute_update).and_raise(update_error)

      expect { described_class.update(job_class, job_id, :set_progress, 75) }
        .to raise_error(update_error)
    end

    it "raises WorkflowNotFoundError when no running workflow is found" do
      allow(default_handle).to receive(:execute_update).and_raise(not_found_error)
      allow(client).to receive(:list_workflows).with(search_query).and_return([])

      expect { described_class.update(job_class, job_id, :set_progress, 75) }
        .to raise_error(ActiveJob::Temporal::WorkflowNotFoundError, /No running workflow/)
    end

    it "validates arguments before contacting Temporal" do
      expect { described_class.update(job_class, "not-a-uuid", :set_progress) }
        .to raise_error(ArgumentError, /Invalid job_id format/)
      expect { described_class.update("SignalQueryJob", job_id, :set_progress) }
        .to raise_error(ArgumentError, /job_class must be a named class/)
      expect { described_class.update(job_class, job_id, "invalid-name") }
        .to raise_error(ArgumentError, /update names/)

      expect(client).not_to have_received(:workflow_handle)
    end
  end
end

RSpec.describe ActiveJob::Temporal do
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "SignalQueryDelegationJob"
    end
  end
  let(:job_id) { "550e8400-e29b-41d4-a716-446655440000" }

  describe ".signal" do
    it "delegates to SignalQuery" do
      allow(ActiveJob::Temporal::SignalQuery).to receive(:signal)

      described_class.signal(job_class, job_id, :pause, "manual hold")

      expect(ActiveJob::Temporal::SignalQuery).to have_received(:signal)
        .with(job_class, job_id, :pause, "manual hold")
    end
  end

  describe ".query" do
    it "delegates to SignalQuery" do
      allow(ActiveJob::Temporal::SignalQuery).to receive(:query).and_return("paused")

      expect(described_class.query(job_class, job_id, :state)).to eq("paused")
      expect(ActiveJob::Temporal::SignalQuery).to have_received(:query)
        .with(
          job_class,
          job_id,
          :state,
          reject_condition: ActiveJob::Temporal::SignalQuery::DEFAULT_REJECT_CONDITION
        )
    end
  end

  describe ".update" do
    it "delegates to SignalQuery" do
      allow(ActiveJob::Temporal::SignalQuery).to receive(:update).and_return("updated")

      expect(described_class.update(job_class, job_id, :set_progress, 75)).to eq("updated")
      expect(ActiveJob::Temporal::SignalQuery).to have_received(:update)
        .with(job_class, job_id, :set_progress, 75)
    end
  end
end
