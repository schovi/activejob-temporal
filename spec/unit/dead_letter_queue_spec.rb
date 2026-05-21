# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/dead_letter_queue"

RSpec.describe ActiveJob::Temporal::DeadLetterQueue do
  let(:client_class) do
    Class.new do
      def start_workflow(_workflow_class, _entry, **_options); end
      def workflow_handle(_workflow_id, run_id: nil); end
      def list_workflows(_query); end
    end
  end
  let(:handle_class) do
    Class.new do
      def query(_query); end
      def signal(_signal, *_args); end
    end
  end
  let(:client) { instance_double(client_class) }
  let(:handle) { instance_double(handle_class) }
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
      allow(client).to receive(:workflow_handle).with("ajdlq:RetryableJob:job-123", run_id: "run-1").and_return(handle)
      allow(handle).to receive(:query).with(:entry).and_return("id" => "ajdlq:RetryableJob:job-123")

      expect(described_class.entry(RetryableJob, "job-123", run_id: "run-1", client: client))
        .to eq("id" => "ajdlq:RetryableJob:job-123")
    end
  end

  describe ".entries" do
    it "lists running dead letter workflows and queries their entries" do
      workflow = instance_double("WorkflowExecution", id: "ajdlq:RetryableJob:job-123", run_id: "run-1")
      allow(client).to receive(:list_workflows)
        .with("WorkflowType='ActiveJobTemporalDeadLetterWorkflow' AND ExecutionStatus='Running'")
        .and_return([workflow])
      allow(client).to receive(:workflow_handle).with("ajdlq:RetryableJob:job-123", run_id: "run-1").and_return(handle)
      allow(handle).to receive(:query).with(:entry).and_return("id" => "ajdlq:RetryableJob:job-123")

      expect(described_class.entries(client: client)).to eq([{ "id" => "ajdlq:RetryableJob:job-123" }])
    end

    it "filters by DLQ task queue and limits queried workflows" do
      query = "WorkflowType='ActiveJobTemporalDeadLetterWorkflow' AND " \
              "ExecutionStatus='Running' AND " \
              "TaskQueue='failed_jobs'"
      broken_handle = instance_double(handle_class)
      workflows = [
        instance_double("WorkflowExecution", id: "ajdlq:RetryableJob:job-broken", run_id: "run-broken"),
        instance_double("WorkflowExecution", id: "ajdlq:RetryableJob:job-123", run_id: "run-1")
      ]
      allow(client).to receive(:list_workflows)
        .with(query)
        .and_return(workflows)
      allow(client).to receive(:workflow_handle)
        .with("ajdlq:RetryableJob:job-broken", run_id: "run-broken")
        .and_return(broken_handle)
      allow(client).to receive(:workflow_handle).with("ajdlq:RetryableJob:job-123", run_id: "run-1").and_return(handle)
      allow(broken_handle).to receive(:query).with(:entry).and_raise(Temporalio::Error::WorkflowQueryFailedError)
      allow(handle).to receive(:query).with(:entry).and_return("id" => "ajdlq:RetryableJob:job-123")

      expect(described_class.entries(queue: "failed_jobs", limit: 1, client: client))
        .to eq([{ "id" => "ajdlq:RetryableJob:job-123" }])
    end
  end

  describe ".retry" do
    it "starts a new ActiveJob workflow and marks the entry retried" do
      allow(client).to receive(:workflow_handle).with("ajdlq:RetryableJob:job-123", run_id: nil).and_return(handle)
      allow(handle).to receive(:query).with(:entry).and_return(entry)
      allow(client).to receive(:start_workflow).and_return(handle)
      allow(handle).to receive(:signal)

      workflow_id = described_class.retry(RetryableJob, "job-123", client: client)

      expect(workflow_id).to eq("ajdlq-retry:ajdlq:RetryableJob:job-123")
      expect(client).to have_received(:start_workflow).with(
        ActiveJob::Temporal::Workflows::AjWorkflow,
        hash_excluding("scheduled_at"),
        id: workflow_id,
        task_queue: "critical-workers",
        id_conflict_policy: Temporalio::WorkflowIDConflictPolicy::FAIL
      )
      expect(handle).to have_received(:signal).with(:mark_retried, workflow_id)
    end

    it "marks the entry retried when another operator already started the deterministic retry workflow" do
      workflow_id = "ajdlq-retry:ajdlq:RetryableJob:job-123"
      already_started = Temporalio::Error::WorkflowAlreadyStartedError.new(
        workflow_id: workflow_id,
        workflow_type: "ActiveJobTemporalAjWorkflow",
        run_id: "retry-run-1"
      )
      allow(client).to receive(:workflow_handle).with("ajdlq:RetryableJob:job-123", run_id: nil).and_return(handle)
      allow(handle).to receive(:query).with(:entry).and_return(entry)
      allow(client).to receive(:start_workflow).and_raise(already_started)
      allow(handle).to receive(:signal)

      expect(described_class.retry(RetryableJob, "job-123", client: client)).to eq(workflow_id)
      expect(handle).to have_received(:signal).with(:mark_retried, workflow_id)
    end

    it "returns the existing retry workflow ID for an already retried entry" do
      retried_entry = entry.merge("state" => "retried", "retry_workflow_id" => "retry-workflow-1")
      allow(client).to receive(:workflow_handle).with("ajdlq:RetryableJob:job-123", run_id: nil).and_return(handle)
      allow(handle).to receive(:query).with(:entry).and_return(retried_entry)

      expect(client).not_to receive(:start_workflow)
      expect(described_class.retry(RetryableJob, "job-123", client: client)).to eq("retry-workflow-1")
    end

    it "does not retry discarded entries" do
      discarded_entry = entry.merge("state" => "discarded")
      allow(client).to receive(:workflow_handle).with("ajdlq:RetryableJob:job-123", run_id: nil).and_return(handle)
      allow(handle).to receive(:query).with(:entry).and_return(discarded_entry)

      expect(client).not_to receive(:start_workflow)
      expect { described_class.retry(RetryableJob, "job-123", client: client) }
        .to raise_error(ActiveJob::Temporal::Error, /state "discarded"/)
    end
  end

  describe ".discard" do
    it "signals the dead letter workflow to discard the entry" do
      allow(client).to receive(:workflow_handle).with("ajdlq:RetryableJob:job-123", run_id: nil).and_return(handle)
      allow(handle).to receive(:signal)

      described_class.discard(RetryableJob, "job-123", reason: "handled elsewhere", client: client)

      expect(handle).to have_received(:signal).with(:discard, "handled elsewhere")
    end
  end
end
