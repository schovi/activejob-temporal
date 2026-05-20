# frozen_string_literal: true

require "spec_helper"
require_relative "../fixtures/sample_jobs"

RSpec.describe ActiveJob::Temporal::Adapter do
  describe ".build_workflow_id" do
    let(:configuration) { ActiveJob::Temporal::Configuration.new }

    before do
      allow(ActiveJob::Temporal).to receive(:config).and_return(configuration)
    end

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

    context "with a custom workflow ID generator configured" do
      it "returns the configured workflow ID" do
        configuration.workflow_id_generator = ->(job) { "custom:#{job.class.name}:#{job.job_id}" }
        job = SimpleJob.new
        job.job_id = "custom-id"

        expect(described_class.build_workflow_id(job)).to eq("custom:SimpleJob:custom-id")
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
  let(:job) do
    job = SimpleJob.new
    job.job_id = "job-123"
    job.queue_name = "mailers"
    job
  end

  let(:client) { instance_double(Temporalio::Client) }
  let(:config) { build_configuration }

  before do
    allow(ActiveJob::Temporal).to receive(:client).and_return(client)
    allow(ActiveJob::Temporal).to receive(:config).and_return(config)
    allow(client).to receive(:start_workflow).and_return("workflow-handle")
    allow(ActiveJob::Temporal::Logger).to receive(:log_event)
  end

  subject(:adapter) { described_class.new }

  describe "#initialize" do
    it "creates a WorkflowEnqueuer instance" do
      expect(adapter.enqueuer).to be_a(ActiveJob::Temporal::WorkflowEnqueuer)
    end
  end

  describe "#enqueue" do
    it "delegates to the enqueuer" do
      result = adapter.enqueue(job)

      expect(client).to have_received(:start_workflow).once
      expect(result).to eq("workflow-handle")
    end

    it "propagates enqueuer errors" do
      allow(client).to receive(:start_workflow).and_raise(StandardError, "workflow failed")

      expect { adapter.enqueue(job) }.to raise_error(ActiveJob::EnqueueError)
    end

    it "handles duplicate enqueue (nil result)" do
      error = Class.new(StandardError)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", error)
      allow(client).to receive(:start_workflow).and_raise(error.new("already started"))

      result = adapter.enqueue(job)

      expect(result).to be_nil
    end
  end

  describe "#enqueue_at" do
    let(:timestamp) { (Time.now + 300).to_i }
    let(:scheduled_time) { Time.at(timestamp) }

    it "converts timestamp to Time and enqueues with scheduled_at" do
      allow(Time).to receive(:at).with(timestamp).and_return(scheduled_time)

      adapter.enqueue_at(job, timestamp)

      expect(Time).to have_received(:at).with(timestamp)
      expect(client).to have_received(:start_workflow).once
    end

    it "returns workflow handle for scheduled jobs" do
      allow(Time).to receive(:at).with(timestamp).and_return(scheduled_time)

      result = adapter.enqueue_at(job, timestamp)

      expect(result).to eq("workflow-handle")
    end

    it "handles duplicate enqueue for scheduled jobs" do
      error = Class.new(StandardError)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", error)
      allow(client).to receive(:start_workflow).and_raise(error.new("already started"))
      allow(Time).to receive(:at).with(timestamp).and_return(scheduled_time)

      result = adapter.enqueue_at(job, timestamp)

      expect(result).to be_nil
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

def build_configuration
  config = ActiveJob::Temporal::Configuration.new
  config.target = "localhost:7233"
  config.namespace = "default"
  config.task_queue_prefix = nil
  config
end
