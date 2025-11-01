# frozen_string_literal: true

require "spec_helper"
require_relative "../fixtures/sample_jobs"

RSpec.describe ActiveJob::Temporal::Adapter do
  describe ".build_workflow_id" do
    context "with a simple job" do
      let(:job) do
        job = SimpleJob.new
        job.job_id = "abc-123"
        job
      end

      it "returns workflow ID in the expected format" do
        workflow_id = described_class.build_workflow_id(job)

        expect(workflow_id).to eq("ajwf:SimpleJob:abc-123")
      end

      it "is deterministic for the same job instance" do
        first = described_class.build_workflow_id(job)
        second = described_class.build_workflow_id(job)

        expect(first).to eq(second)
      end
    end

    context "with different job classes sharing job_id" do
      let(:simple_job) do
        job = SimpleJob.new
        job.job_id = "shared-id"
        job
      end

      let(:scheduled_job) do
        job = ScheduledJob.new
        job.job_id = "shared-id"
        job
      end

      it "produces different workflow IDs" do
        simple_id = described_class.build_workflow_id(simple_job)
        scheduled_id = described_class.build_workflow_id(scheduled_job)

        expect(simple_id).to eq("ajwf:SimpleJob:shared-id")
        expect(scheduled_id).to eq("ajwf:ScheduledJob:shared-id")
        expect(simple_id).not_to eq(scheduled_id)
      end
    end

    context "with the same job class and different job IDs" do
      it "returns unique workflow IDs" do
        job_one = SimpleJob.new
        job_one.job_id = "id-1"

        job_two = SimpleJob.new
        job_two.job_id = "id-2"

        id_one = described_class.build_workflow_id(job_one)
        id_two = described_class.build_workflow_id(job_two)

        expect(id_one).to eq("ajwf:SimpleJob:id-1")
        expect(id_two).to eq("ajwf:SimpleJob:id-2")
        expect(id_one).not_to eq(id_two)
      end
    end
  end

  describe ".resolve_task_queue" do
    let(:job) { SimpleJob.new }

    context "when no prefix is configured" do
      before do
        allow(ActiveJob::Temporal.config).to receive(:task_queue_prefix).and_return(nil)
      end

      it "returns the job queue name" do
        job.queue_name = "billing"

        expect(described_class.resolve_task_queue(job)).to eq("billing")
      end

      it "falls back to the default queue when queue_name is nil" do
        job.queue_name = nil

        expect(described_class.resolve_task_queue(job)).to eq("default")
      end

      it "treats blank queue names as default" do
        job.queue_name = "   "

        expect(described_class.resolve_task_queue(job)).to eq("default")
      end
    end

    context "when a prefix is configured" do
      before do
        allow(ActiveJob::Temporal.config).to receive(:task_queue_prefix).and_return("prod-")
      end

      it "prepends the prefix to the queue name" do
        job.queue_name = "billing"

        expect(described_class.resolve_task_queue(job)).to eq("prod-billing")
      end

      it "prepends the prefix to the default queue" do
        job.queue_name = nil

        expect(described_class.resolve_task_queue(job)).to eq("prod-default")
      end

      it "works for other queue names" do
        job.queue_name = "mailers"

        expect(described_class.resolve_task_queue(job)).to eq("prod-mailers")
      end
    end

    context "when the prefix is an empty string" do
      before do
        allow(ActiveJob::Temporal.config).to receive(:task_queue_prefix).and_return("")
      end

      it "treats an empty prefix as absent" do
        job.queue_name = "exports"

        expect(described_class.resolve_task_queue(job)).to eq("exports")
      end
    end
  end
end

RSpec.describe ActiveJob::QueueAdapters::TemporalAdapter do
  subject(:adapter) { described_class.new }

  let(:job) do
    job = SimpleJob.new
    job.job_id = "job-123"
    job.queue_name = "mailers"
    job
  end

  let(:retry_policy) do
    {
      initial_interval: 30.0,
      backoff_coefficient: 2.0,
      maximum_attempts: 3,
      non_retryable_error_types: []
    }
  end

  let(:payload) do
    {
      job_class: "SimpleJob",
      job_id: "job-123",
      queue_name: "mailers",
      arguments: [],
      retry_policy: retry_policy
    }
  end

  let(:workflow_id) { "ajwf:SimpleJob:job-123" }
  let(:task_queue) { "mailers" }
  let(:search_attributes) { { ajClass: "SimpleJob", ajQueue: "mailers" } }
  let(:client) { instance_double("TemporalClient") }
  let(:workflow_handle) { instance_double("WorkflowHandle") }

  before do
    allow(ActiveJob::Temporal::Payload).to receive(:from_job).with(job, scheduled_at: nil).and_return({
      job_class: "SimpleJob",
      job_id: "job-123",
      queue_name: "mailers",
      arguments: []
    })
    allow(ActiveJob::Temporal::RetryMapper).to receive(:for).with(SimpleJob).and_return(retry_policy)
    allow(ActiveJob::Temporal::Adapter).to receive(:build_workflow_id).with(job).and_return(workflow_id)
    allow(ActiveJob::Temporal::Adapter).to receive(:resolve_task_queue).with(job).and_return(task_queue)
    allow(ActiveJob::Temporal::SearchAttributes).to receive(:for).with(job).and_return(search_attributes)
    allow(ActiveJob::Temporal).to receive(:client).and_return(client)
    allow(client).to receive(:start_workflow).and_return(workflow_handle)
    allow(ActiveJob::Temporal::Logger).to receive(:log_event)
    allow(ActiveJob::Temporal.config).to receive(:enable_search_attributes).and_return(true)
  end

  describe "#enqueue" do
    it "serializes payload and starts workflow" do
      result = adapter.enqueue(job)

      expect(result).to eq(workflow_handle)
      expect(client).to have_received(:start_workflow).with(
        ActiveJob::Temporal::Workflows::AjWorkflow,
        payload,
        id: workflow_id,
        task_queue: task_queue,
        id_conflict_policy: Temporalio::WorkflowIDConflictPolicy::FAIL,
        search_attributes: search_attributes
      )
      expect(ActiveJob::Temporal::Logger).to have_received(:log_event).with(
        "workflow_enqueued",
        workflow_id: workflow_id,
        job_class: "SimpleJob",
        job_id: "job-123",
        queue: "mailers",
        task_queue: task_queue,
        duplicate: false
      )
    end

    it "propagates serialization errors" do
      error = ActiveJob::SerializationError.new("too large")
      allow(ActiveJob::Temporal::Payload).to receive(:from_job).and_raise(error)

      expect { adapter.enqueue(job) }.to raise_error(ActiveJob::SerializationError, "too large")
    end

    it "wraps Temporal client failures in ActiveJob::EnqueueError" do
      allow(client).to receive(:start_workflow).and_raise(StandardError, "connection refused")

      expect { adapter.enqueue(job) }
        .to raise_error(ActiveJob::EnqueueError, /Failed to enqueue job SimpleJob \(job-123\): connection refused/)
    end

    it "treats duplicate workflow IDs as successful enqueue" do
      duplicate_error = Class.new(StandardError)
      stub_const("Temporalio", Module.new) unless defined?(Temporalio)
      stub_const("Temporalio::Client", Module.new) unless defined?(Temporalio::Client)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", duplicate_error)
      allow(client).to receive(:start_workflow).and_raise(duplicate_error.new("already started"))

      result = adapter.enqueue(job)

      expect(result).to be_nil
      expect(ActiveJob::Temporal::Logger).to have_received(:log_event).with(
        "workflow_enqueued",
        workflow_id: workflow_id,
        job_class: "SimpleJob",
        job_id: "job-123",
        queue: "mailers",
        task_queue: task_queue,
        duplicate: true
      )
    end
  end

  describe "#enqueue_at" do
    let(:job) do
      job = ScheduledJob.new
      job.job_id = "job-456"
      job.queue_name = "billing"
      job
    end

    let(:timestamp) { (Time.now + 300).to_i }
    let(:scheduled_time) { Time.at(timestamp) }
    let(:workflow_id) { "ajwf:ScheduledJob:job-456" }
    let(:task_queue) { "billing" }
    let(:search_attributes) { { ajClass: "ScheduledJob", ajQueue: "billing" } }
    let(:scheduled_retry_policy) do
      {
        initial_interval: 15.0,
        backoff_coefficient: 1.5,
        maximum_attempts: 2,
        non_retryable_error_types: []
      }
    end

    let(:payload) do
      {
        job_class: "ScheduledJob",
        job_id: "job-456",
        queue_name: "billing",
        arguments: [],
        scheduled_at: scheduled_time.iso8601,
        retry_policy: scheduled_retry_policy
      }
    end

    before do
      allow(Time).to receive(:at).with(timestamp).and_return(scheduled_time)
      allow(ActiveJob::Temporal::Payload)
        .to receive(:from_job)
        .with(job, scheduled_at: scheduled_time)
        .and_return({
          job_class: "ScheduledJob",
          job_id: "job-456",
          queue_name: "billing",
          arguments: [],
          scheduled_at: scheduled_time.iso8601
        })
      allow(ActiveJob::Temporal::RetryMapper).to receive(:for).with(ScheduledJob).and_return(scheduled_retry_policy)
      allow(ActiveJob::Temporal::Adapter).to receive(:build_workflow_id).with(job).and_return(workflow_id)
      allow(ActiveJob::Temporal::Adapter).to receive(:resolve_task_queue).with(job).and_return(task_queue)
      allow(ActiveJob::Temporal::SearchAttributes).to receive(:for).with(job).and_return(search_attributes)
    end

    it "converts the timestamp to a Time and passes it to Payload.from_job" do
      adapter.enqueue_at(job, timestamp)

      expect(Time).to have_received(:at).with(timestamp)
      expect(ActiveJob::Temporal::Payload).to have_received(:from_job).with(job, scheduled_at: scheduled_time)
    end

    it "includes scheduled_at in ISO8601 format within the payload" do
      adapter.enqueue_at(job, timestamp)

      expect(payload[:scheduled_at]).to eq(scheduled_time.iso8601)
    end

    it "starts the workflow immediately with the scheduled payload" do
      adapter.enqueue_at(job, timestamp)

      expect(client).to have_received(:start_workflow).with(
        ActiveJob::Temporal::Workflows::AjWorkflow,
        payload,
        id: workflow_id,
        task_queue: task_queue,
        id_conflict_policy: Temporalio::WorkflowIDConflictPolicy::FAIL,
        search_attributes: search_attributes
      )
    end

    it "logs the enqueue event with scheduled_at metadata" do
      adapter.enqueue_at(job, timestamp)

      expect(ActiveJob::Temporal::Logger).to have_received(:log_event).with(
        "workflow_enqueued",
        workflow_id: workflow_id,
        job_class: "ScheduledJob",
        job_id: "job-456",
        queue: "billing",
        task_queue: task_queue,
        duplicate: false,
        scheduled_at: scheduled_time.iso8601
      )
    end
  end

  describe "#enqueue_after_transaction_commit?" do
    it "returns true to enable transaction-aware enqueuing" do
      expect(adapter.enqueue_after_transaction_commit?).to be true
    end
  end
end

RSpec.describe "ActiveJob adapter registration" do
  describe ".lookup" do
    it "returns the Temporal adapter when requested by symbol" do
      adapter_class = ActiveJob::QueueAdapters.lookup(:temporal)

      expect(adapter_class).to eq(ActiveJob::QueueAdapters::TemporalAdapter)
    end
  end
end
