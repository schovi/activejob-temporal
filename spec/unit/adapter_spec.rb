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
    let(:configuration) { ActiveJob::Temporal::Configuration.new }
    let(:job) { SimpleJob.new }

    before do
      allow(ActiveJob::Temporal).to receive(:config).and_return(configuration)
    end

    context "when no prefix is configured" do
      before do
        configuration.task_queue_prefix = nil
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
        configuration.task_queue_prefix = "prod-"
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
        configuration.task_queue_prefix = ""
      end

      it "treats an empty prefix as absent" do
        job.queue_name = "exports"

        expect(described_class.resolve_task_queue(job)).to eq("exports")
      end
    end

    context "when priority task queues are not configured" do
      it "does not evaluate dynamic job priorities" do
        job.queue_name = "mailers"
        job.define_singleton_method(:priority) { raise "priority evaluated" }

        expect(described_class.resolve_task_queue(job)).to eq("mailers")
      end
    end

    context "when priority task queues are configured" do
      before do
        configuration.priority_task_queues = {
          10 => "high_priority",
          90 => "low_priority"
        }
      end

      it "routes numeric priorities to the configured task queue" do
        job.queue_name = "default"
        job.define_singleton_method(:priority) { 10 }

        expect(described_class.resolve_task_queue(job)).to eq("high_priority")
      end

      it "routes priorities assigned through ActiveJob set" do
        priority_job_class = Class.new(ActiveJob::Base) do
          self.queue_adapter = :test

          def self.name = "PriorityRoutingJob"

          def perform; end
        end
        job = priority_job_class.set(priority: 10).perform_later
        job.queue_name = "default"

        expect(described_class.resolve_task_queue(job)).to eq("high_priority")
      end

      it "routes other numeric priorities to the configured task queue" do
        job.queue_name = "default"
        job.define_singleton_method(:priority) { 90 }

        expect(described_class.resolve_task_queue(job)).to eq("low_priority")
      end

      it "falls back to the job queue when priority is unmapped" do
        job.queue_name = "mailers"
        job.define_singleton_method(:priority) { 50 }

        expect(described_class.resolve_task_queue(job)).to eq("mailers")
      end

      it "falls back to the job queue when priority is not an integer" do
        job.queue_name = "mailers"
        job.define_singleton_method(:priority) { "10" }

        expect(described_class.resolve_task_queue(job)).to eq("mailers")
      end

      it "applies task queue prefixes to priority task queues" do
        configuration.task_queue_prefix = "prod-"
        job.queue_name = "default"
        job.define_singleton_method(:priority) { 10 }

        expect(described_class.resolve_task_queue(job)).to eq("prod-high_priority")
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

    it "uses the current Temporal client when enqueueing" do
      first_client = instance_double(Temporalio::Client)
      second_client = instance_double(Temporalio::Client)
      first_job = job
      second_job = ScheduledJob.new

      allow(first_client).to receive(:start_workflow).and_return("first-handle")
      allow(second_client).to receive(:start_workflow).and_return("second-handle")
      allow(ActiveJob::Temporal).to receive(:client).and_return(first_client, second_client)

      expect(adapter.enqueue(first_job)).to eq("first-handle")
      expect(adapter.enqueue(second_job)).to eq("second-handle")
      expect(first_client).to have_received(:start_workflow).once
      expect(second_client).to have_received(:start_workflow).once
    end

    it "propagates enqueuer errors" do
      allow(client).to receive(:start_workflow).and_raise(StandardError, "workflow failed")

      expect { adapter.enqueue(job) }.to raise_error(ActiveJob::EnqueueError)
    end

    it "raises a duplicate enqueue error for duplicate workflows" do
      error = Class.new(StandardError)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", error)
      allow(client).to receive(:start_workflow).and_raise(error.new("already started"))

      expect { adapter.enqueue(job) }.to raise_error(ActiveJob::Temporal::DuplicateEnqueueError)
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

    it "raises a duplicate enqueue error for duplicate scheduled workflows" do
      error = Class.new(StandardError)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", error)
      allow(client).to receive(:start_workflow).and_raise(error.new("already started"))
      allow(Time).to receive(:at).with(timestamp).and_return(scheduled_time)

      expect { adapter.enqueue_at(job, timestamp) }.to raise_error(ActiveJob::Temporal::DuplicateEnqueueError)
    end

    it "rejects past timestamps before starting a workflow" do
      past_timestamp = (Time.now - 60).to_i

      expect do
        adapter.enqueue_at(job, past_timestamp)
      end.to raise_error(ArgumentError, /scheduled_at must be in the future/)

      expect(client).not_to have_received(:start_workflow)
    end
  end

  describe "#enqueue_after_transaction_commit?" do
    it "returns true to enable transaction-aware enqueuing" do
      expect(adapter.enqueue_after_transaction_commit?).to be true
    end
  end
end

RSpec.describe "Temporal duplicate enqueue handling through ActiveJob" do
  let(:client) { instance_double(Temporalio::Client) }
  let(:config) { build_configuration }
  let(:duplicate_error) { Class.new(StandardError) }

  before do
    stub_const("Temporalio::Client::WorkflowAlreadyStartedError", duplicate_error)
    allow(ActiveJob::Temporal).to receive(:client).and_return(client)
    allow(ActiveJob::Temporal).to receive(:config).and_return(config)
    allow(client).to receive(:start_workflow).and_raise(duplicate_error.new("already started"))
    allow(ActiveJob::Temporal::Logger).to receive(:log_event)
  end

  it "returns false and exposes a duplicate enqueue error to perform_later callers" do
    job_class = stub_const("DuplicatePerformLaterJob", Class.new(ActiveJob::Base) do
      self.queue_adapter = :temporal

      def perform; end
    end)
    enqueued_job = nil

    result = job_class.perform_later { |job| enqueued_job = job }

    expect(result).to be false
    expect(enqueued_job.successfully_enqueued?).to be false
    expect(enqueued_job.enqueue_error).to be_a(ActiveJob::Temporal::DuplicateEnqueueError)
    expect(enqueued_job.enqueue_error.message).to include("already enqueued")
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
