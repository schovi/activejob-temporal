# frozen_string_literal: true

require "spec_helper"
require_relative "../fixtures/sample_jobs"

RSpec.describe ActiveJob::Temporal::WorkflowEnqueuer do
  let(:client) { instance_double(Temporalio::Client) }
  let(:config) { build_configuration }
  let(:logger) { instance_double(Logger) }
  let(:enqueuer) { described_class.new(client, config, logger) }

  describe "#enqueue" do
    let(:job) do
      job = SimpleJob.new
      job.job_id = "test-job-id"
      job
    end

    before do
      allow(client).to receive(:start_workflow).and_return("workflow-handle")
      allow(ActiveJob::Temporal::Logger).to receive(:log_event)
    end

    it "delegates to client.start_workflow" do
      enqueuer.enqueue(job)

      expect(client).to have_received(:start_workflow).once
    end

    it "returns the workflow handle" do
      handle = "test-workflow-handle"
      allow(client).to receive(:start_workflow).and_return(handle)

      result = enqueuer.enqueue(job)

      expect(result).to eq(handle)
    end

    it "includes the workflow ID in options" do
      allow(client).to receive(:start_workflow) do |_klass, _payload, **options|
        expect(options[:id]).to eq("ajwf:SimpleJob:test-job-id")
        "handle"
      end

      enqueuer.enqueue(job)
    end

    it "includes FAIL conflict policy" do
      allow(client).to receive(:start_workflow) do |_klass, _payload, **options|
        expect(options[:id_conflict_policy]).to eq(Temporalio::WorkflowIDConflictPolicy::FAIL)
        "handle"
      end

      enqueuer.enqueue(job)
    end

    it "returns nil for duplicate workflows" do
      error = Class.new(StandardError)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", error)
      allow(client).to receive(:start_workflow).and_raise(error.new("already started"))

      result = enqueuer.enqueue(job)

      expect(result).to be_nil
    end

    it "raises ActiveJob::EnqueueError for non-duplicate errors" do
      allow(client).to receive(:start_workflow).and_raise(StandardError, "Connection failed")

      expect do
        enqueuer.enqueue(job)
      end.to raise_error(ActiveJob::EnqueueError)
    end

    context "with scheduled_at" do
      it "accepts scheduled_at parameter" do
        scheduled_time = 1.hour.from_now

        allow(client).to receive(:start_workflow) do |_klass, payload, **_options|
          # Payload contains scheduled_at as ISO8601 string
          expect(payload[:scheduled_at]).to eq(scheduled_time.iso8601)
          "handle"
        end

        enqueuer.enqueue(job, scheduled_at: scheduled_time)
      end
    end

    context "with blank queue name" do
      it "raises ConfigurationError" do
        allow(job).to receive(:queue_name).and_return(nil)

        expect do
          enqueuer.enqueue(job)
        end.to raise_error(ActiveJob::Temporal::ConfigurationError, /queue name cannot be blank/)
      end
    end
  end

  describe "initialization" do
    it "accepts optional logger" do
      custom_logger = instance_double(Logger)
      enqueuer_with_logger = described_class.new(client, config, custom_logger)

      expect(enqueuer_with_logger).to be_a(described_class)
    end

    it "uses config logger when not provided" do
      enqueuer_without_logger = described_class.new(client, config)

      expect(enqueuer_without_logger).to be_a(described_class)
    end
  end

  private

  def build_configuration
    config = ActiveJob::Temporal::Configuration.new
    config.target = "localhost:7233"
    config.namespace = "default"
    config.task_queue_prefix = nil
    config
  end
end
