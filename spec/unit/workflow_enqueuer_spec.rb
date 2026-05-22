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
      allow(ActiveJob::Temporal::AuditLog).to receive(:record)
      allow(ActiveJob::Temporal::Metrics).to receive(:record_enqueue)
    end

    it "delegates to client.start_workflow" do
      enqueuer.enqueue(job)

      expect(client).to have_received(:start_workflow).once
    end

    it "records enqueue metrics after a workflow starts" do
      enqueuer.enqueue(job)

      expect(ActiveJob::Temporal::Metrics).to have_received(:record_enqueue).with(
        job: job,
        duplicate: false
      )
    end

    it "records an audit event after a workflow starts" do
      enqueuer.enqueue(job)

      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.enqueued",
        hash_including(
          workflow_id: "ajwf:SimpleJob:test-job-id",
          job_class: "SimpleJob",
          job_id: "test-job-id",
          queue: "default",
          task_queue: "default",
          duplicate: false
        )
      )
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

    it "uses the injected workflow ID builder" do
      workflow_id_builder = instance_double(ActiveJob::Temporal::WorkflowIdBuilder)
      enqueuer = described_class.new(client, config, logger, workflow_id_builder: workflow_id_builder)

      allow(workflow_id_builder).to receive(:build).with(job).and_return("custom-workflow-id")
      allow(client).to receive(:start_workflow) do |_klass, _payload, **options|
        expect(options[:id]).to eq("custom-workflow-id")
        "handle"
      end

      enqueuer.enqueue(job)
    end

    it "builds encrypted payloads with the target workflow context" do
      payload_builder = instance_double(ActiveJob::Temporal::JobPayloadBuilder)
      enqueuer = described_class.new(client, config, logger, payload_builder: payload_builder)
      payload = { job_class: "SimpleJob", job_id: job.job_id, queue_name: "default" }

      allow(payload_builder).to receive(:build)
        .with(
          job,
          scheduled_at: nil,
          encryption_context: { namespace: "default", workflow_id: "ajwf:SimpleJob:test-job-id" }
        )
        .and_return(payload)

      enqueuer.enqueue(job)

      expect(payload_builder).to have_received(:build).with(
        job,
        scheduled_at: nil,
        encryption_context: { namespace: "default", workflow_id: "ajwf:SimpleJob:test-job-id" }
      )
    end

    it "uses the configured workflow ID generator" do
      config.workflow_id_generator = ->(job) { "custom:#{job.class.name}:#{job.job_id}" }
      enqueuer = described_class.new(client, config, logger)

      allow(client).to receive(:start_workflow) do |_klass, _payload, **options|
        expect(options[:id]).to eq("custom:SimpleJob:test-job-id")
        "handle"
      end

      enqueuer.enqueue(job)
    end

    it "rejects invalid configured workflow IDs before starting a workflow" do
      config.workflow_id_generator = ->(_job) { "invalid workflow/id" }
      enqueuer = described_class.new(client, config, logger)

      expect { enqueuer.enqueue(job) }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /invalid workflow ID/)
      expect(client).not_to have_received(:start_workflow)
    end

    it "includes FAIL conflict policy" do
      allow(client).to receive(:start_workflow) do |_klass, _payload, **options|
        expect(options[:id_conflict_policy]).to eq(Temporalio::WorkflowIDConflictPolicy::FAIL)
        "handle"
      end

      enqueuer.enqueue(job)
    end

    it "uses the configured task queue for job priority" do
      config.priority_task_queues = { 10 => "high_priority" }
      priority_job_class = Class.new(ActiveJob::Base) do
        self.queue_adapter = :test

        def self.name = "PriorityEnqueueJob"

        def perform; end
      end
      priority_job = priority_job_class.set(priority: 10).perform_later
      priority_job.job_id = "priority-job-id"
      priority_job.queue_name = "default"

      allow(client).to receive(:start_workflow) do |_klass, _payload, **options|
        expect(options[:task_queue]).to eq("high_priority")
        "handle"
      end

      enqueuer.enqueue(priority_job)
    end

    it "records enqueue metrics with the ActiveJob queue when priority maps to another task queue" do
      config.priority_task_queues = { 10 => "high_priority" }
      priority_job_class = Class.new(ActiveJob::Base) do
        self.queue_adapter = :test

        def self.name = "PriorityMetricJob"

        def perform; end
      end
      priority_job = priority_job_class.set(priority: 10).perform_later
      priority_job.job_id = "priority-metric-job-id"
      priority_job.queue_name = "default"

      allow(client).to receive(:start_workflow) do |_klass, _payload, **options|
        expect(options[:task_queue]).to eq("high_priority")
        "handle"
      end

      enqueuer.enqueue(priority_job)

      expect(ActiveJob::Temporal::Metrics).to have_received(:record_enqueue).with(
        job: priority_job,
        duplicate: false
      )
    end

    it "includes global activity timeout defaults in the payload" do
      config.default_heartbeat_timeout = 45.seconds
      config.default_schedule_to_start_timeout = 2.minutes
      config.default_schedule_to_close_timeout = 20.minutes

      allow(client).to receive(:start_workflow) do |_klass, payload, **_options|
        expect(payload[:default_activity_options]).to eq(
          start_to_close_timeout: 900.0,
          schedule_to_close_timeout: 1200.0,
          schedule_to_start_timeout: 120.0,
          heartbeat_timeout: 45.0
        )
        "handle"
      end

      enqueuer.enqueue(job)
    end

    it "includes job tags in search attributes" do
      job.define_singleton_method(:temporal_tags) { %w[urgent customer_123] }
      aj_tags_key = Temporalio::SearchAttributes::Key.new("ajTags", Temporalio::SearchAttributes::IndexedValueType::KEYWORD_LIST)

      allow(client).to receive(:start_workflow) do |_klass, _payload, **options|
        expect(options[:search_attributes][aj_tags_key]).to eq(%w[urgent customer_123])
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
      expect(ActiveJob::Temporal::Metrics).to have_received(:record_enqueue).with(
        job: job,
        duplicate: true
      )
      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.enqueued",
        hash_including(
          job_id: "test-job-id",
          duplicate: true
        )
      )
    end

    it "returns nil for current SDK duplicate workflow errors" do
      error = Temporalio::Error::WorkflowAlreadyStartedError.new(
        workflow_id: "ajwf:SimpleJob:test-job-id",
        workflow_type: "ActiveJob::Temporal::Workflows::AjWorkflow",
        run_id: "test-run-id"
      )
      allow(client).to receive(:start_workflow).and_raise(error)

      result = enqueuer.enqueue(job)

      expect(result).to be_nil
      expect(ActiveJob::Temporal::Metrics).to have_received(:record_enqueue).with(
        job: job,
        duplicate: true
      )
    end

    it "returns nil for already-exists RPC duplicate workflow errors" do
      error = Class.new(StandardError) do
        attr_reader :code

        def initialize
          @code = Temporalio::Error::RPCError::Code::ALREADY_EXISTS
          super("Workflow execution already started")
        end
      end
      allow(client).to receive(:start_workflow).and_raise(error.new)

      result = enqueuer.enqueue(job)

      expect(result).to be_nil
      expect(ActiveJob::Temporal::Metrics).to have_received(:record_enqueue).with(
        job: job,
        duplicate: true
      )
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

      it "rejects malformed scheduled_at values before starting a workflow" do
        expect do
          enqueuer.enqueue(job, scheduled_at: "not-a-date")
        end.to raise_error(ArgumentError, /scheduled_at must be/)

        expect(client).not_to have_received(:start_workflow)
      end

      it "rejects past scheduled_at values before starting a workflow" do
        expect do
          enqueuer.enqueue(job, scheduled_at: 1.minute.ago)
        end.to raise_error(ArgumentError, /scheduled_at must be in the future/)

        expect(client).not_to have_received(:start_workflow)
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

    context "with temporal_options" do
      let(:timeout_job_class) do
        Class.new(ActiveJob::Base) do
          def self.name
            "TimeoutJob"
          end

          temporal_options(
            start_to_close_timeout: 2.hours,
            heartbeat_timeout: 30.seconds
          )

          def perform; end
        end
      end

      let(:timeout_job) do
        job = timeout_job_class.new
        job.job_id = "timeout-job-id"
        job.queue_name = "default"
        job
      end

      it "includes temporal_options in the payload" do
        allow(client).to receive(:start_workflow) do |_klass, payload, **_options|
          expect(payload[:default_activity_options]).to include(start_to_close_timeout: 900.0)
          expect(payload[:temporal_options]).to be_present
          expect(payload[:temporal_options][:start_to_close_timeout]).to eq(7200.0)
          expect(payload[:temporal_options][:heartbeat_timeout]).to eq(30.0)
          "handle"
        end

        enqueuer.enqueue(timeout_job)
      end

      it "omits temporal_options from payload when not defined" do
        allow(client).to receive(:start_workflow) do |_klass, payload, **_options|
          expect(payload[:temporal_options]).to be_nil
          "handle"
        end

        enqueuer.enqueue(job)
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
