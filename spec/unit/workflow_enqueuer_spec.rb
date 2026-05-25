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
      allow(ActiveJob::Temporal::Observability).to receive(:emit)
    end

    it "delegates to client.start_workflow" do
      enqueuer.enqueue(job)

      expect(client).to have_received(:start_workflow).once
    end

    it "emits enqueue observability after a workflow starts" do
      enqueuer.enqueue(job)

      expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
        :enqueue,
        hash_including(
          job_class: "SimpleJob",
          job_id: "test-job-id",
          queue: "default",
          workflow_id: "ajwf:SimpleJob:test-job-id",
          task_queue: "default",
          duplicate: false
        )
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

    it "returns the workflow handle when enqueue logging fails after Temporal accepts the workflow" do
      allow(ActiveJob::Temporal::Logger).to receive(:log_event).and_raise(StandardError, "logger down")
      allow(ActiveJob::Temporal::Logger).to receive(:warn)

      result = enqueuer.enqueue(job)

      expect(result).to eq("workflow-handle")
      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.enqueued",
        hash_including(job_id: "test-job-id", duplicate: false)
      )
      expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
        :enqueue,
        hash_including(job_id: "test-job-id", duplicate: false)
      )
      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "workflow_enqueue_side_effect_failed",
        hash_including(
          side_effect: "log",
          workflow_id: "ajwf:SimpleJob:test-job-id",
          job_id: "test-job-id",
          error_class: "StandardError"
        )
      )
    end

    it "returns the workflow handle when enqueue auditing fails after Temporal accepts the workflow" do
      allow(ActiveJob::Temporal::AuditLog).to receive(:record).and_raise(StandardError, "audit down")
      allow(ActiveJob::Temporal::Logger).to receive(:warn)

      result = enqueuer.enqueue(job)

      expect(result).to eq("workflow-handle")
      expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
        :enqueue,
        hash_including(job_id: "test-job-id", duplicate: false)
      )
      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "workflow_enqueue_side_effect_failed",
        hash_including(side_effect: "audit", job_id: "test-job-id", error_class: "StandardError")
      )
    end

    it "returns the workflow handle when enqueue observability fails after Temporal accepts the workflow" do
      allow(ActiveJob::Temporal::Observability).to receive(:emit) do |event_name, *_arguments|
        raise StandardError, "metrics down" if event_name == :enqueue
      end
      allow(ActiveJob::Temporal::Logger).to receive(:warn)

      result = enqueuer.enqueue(job)

      expect(result).to eq("workflow-handle")
      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "workflow_enqueue_side_effect_failed",
        hash_including(side_effect: "observability", job_id: "test-job-id", error_class: "StandardError")
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

    it "rejects blank dead letter queues before starting a workflow" do
      payload_builder = instance_double(ActiveJob::Temporal::JobPayloadBuilder)
      enqueuer = described_class.new(client, config, logger, payload_builder: payload_builder)
      payload = {
        job_class: "SimpleJob",
        job_id: job.job_id,
        queue_name: "default",
        dead_letter: { queue: " " }
      }

      allow(payload_builder).to receive(:build).and_return(payload)

      expect { enqueuer.enqueue(job) }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /dead_letter\.queue cannot be blank/)
      expect(client).not_to have_received(:start_workflow)
    end

    it "rejects blank chain dead letter queues before starting a workflow" do
      payload_builder = instance_double(ActiveJob::Temporal::JobPayloadBuilder)
      enqueuer = described_class.new(client, config, logger, payload_builder: payload_builder)
      payload = {
        job_class: "SimpleJob",
        job_id: job.job_id,
        queue_name: "default",
        chain: [
          {
            job_class: "NextJob",
            job_id: "#{job.job_id}:chain:1",
            queue_name: "default",
            arguments: [],
            dead_letter: { queue: nil }
          }
        ]
      }

      allow(payload_builder).to receive(:build).and_return(payload)

      expect { enqueuer.enqueue(job) }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /chain\.dead_letter\.queue cannot be blank/)
      expect(client).not_to have_received(:start_workflow)
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
      config.workflow_id_generator = ->(_job) { "invalid\nworkflow" }
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

      expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
        :enqueue,
        hash_including(
          job_class: "PriorityMetricJob",
          job_id: "priority-metric-job-id",
          queue: "default",
          task_queue: "high_priority",
          duplicate: false
        )
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

    it "raises a duplicate enqueue error for duplicate workflows" do
      error = Class.new(StandardError)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", error)
      allow(client).to receive(:start_workflow).and_raise(error.new("already started"))

      expect { enqueuer.enqueue(job) }
        .to raise_error(ActiveJob::Temporal::DuplicateEnqueueError, /already enqueued/)

      expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
        :enqueue,
        hash_including(
          job_class: "SimpleJob",
          job_id: "test-job-id",
          duplicate: true
        )
      )
      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.enqueued",
        hash_including(
          job_id: "test-job-id",
          duplicate: true
        )
      )
    end

    it "raises a duplicate enqueue error for duplicate workflows when enqueue logging fails" do
      error = Class.new(StandardError)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", error)
      allow(client).to receive(:start_workflow).and_raise(error.new("already started"))
      allow(ActiveJob::Temporal::Logger).to receive(:log_event).and_raise(StandardError, "logger down")
      allow(ActiveJob::Temporal::Logger).to receive(:warn)

      expect { enqueuer.enqueue(job) }
        .to raise_error(ActiveJob::Temporal::DuplicateEnqueueError, /already enqueued/)

      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.enqueued",
        hash_including(job_id: "test-job-id", duplicate: true)
      )
      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "workflow_enqueue_side_effect_failed",
        hash_including(side_effect: "log", job_id: "test-job-id", duplicate: true)
      )
    end

    it "raises a duplicate enqueue error for current SDK duplicate workflow errors" do
      error = Temporalio::Error::WorkflowAlreadyStartedError.new(
        workflow_id: "ajwf:SimpleJob:test-job-id",
        workflow_type: "ActiveJob::Temporal::Workflows::AjWorkflow",
        run_id: "test-run-id"
      )
      allow(client).to receive(:start_workflow).and_raise(error)

      expect { enqueuer.enqueue(job) }
        .to raise_error(ActiveJob::Temporal::DuplicateEnqueueError, /already enqueued/)

      expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
        :enqueue,
        hash_including(job_class: "SimpleJob", job_id: "test-job-id", duplicate: true)
      )
    end

    it "raises a duplicate enqueue error for already-exists RPC duplicate workflow errors" do
      error = Class.new(StandardError) do
        attr_reader :code

        def initialize
          @code = Temporalio::Error::RPCError::Code::ALREADY_EXISTS
          super("Workflow execution already started")
        end
      end
      allow(client).to receive(:start_workflow).and_raise(error.new)

      expect { enqueuer.enqueue(job) }
        .to raise_error(ActiveJob::Temporal::DuplicateEnqueueError, /already enqueued/)

      expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
        :enqueue,
        hash_including(job_class: "SimpleJob", job_id: "test-job-id", duplicate: true)
      )
    end

    it "raises ActiveJob::EnqueueError for non-duplicate errors" do
      original_error = StandardError.new("Connection failed")
      allow(client).to receive(:start_workflow).and_raise(original_error)

      expect do
        enqueuer.enqueue(job)
      end.to raise_error(ActiveJob::EnqueueError) { |error|
        expect(error.cause).to be(original_error)
      }
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

      it "treats scheduled_at equal to now as immediate" do
        now = Time.utc(2026, 5, 25, 12, 0, 0)
        allow(Time).to receive(:now).and_return(now)
        allow(client).to receive(:start_workflow) do |_klass, payload, **_options|
          expect(payload[:scheduled_at]).to be_nil
          "handle"
        end

        expect(enqueuer.enqueue(job, scheduled_at: now)).to eq("handle")
      end

      it "treats slightly past scheduled_at values as immediate" do
        now = Time.utc(2026, 5, 25, 12, 0, 0)
        allow(Time).to receive(:now).and_return(now)
        allow(client).to receive(:start_workflow) do |_klass, payload, **_options|
          expect(payload[:scheduled_at]).to be_nil
          "handle"
        end

        expect(enqueuer.enqueue(job, scheduled_at: now - 0.1)).to eq("handle")
      end

      it "rejects malformed scheduled_at values before starting a workflow" do
        expect do
          enqueuer.enqueue(job, scheduled_at: "not-a-date")
        end.to raise_error(ArgumentError, /scheduled_at must be/)

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

  describe "#enqueue_batch" do
    let(:first_job) do
      job = SimpleJob.new
      job.job_id = "batch-job-1"
      job.queue_name = "mailers"
      job
    end

    let(:second_job) do
      job = ScheduledJob.new
      job.job_id = "batch-job-2"
      job.queue_name = "reports"
      job
    end

    before do
      allow(client).to receive(:start_workflow).and_return("workflow-handle")
      allow(ActiveJob::Temporal::Logger).to receive(:log_event)
      allow(ActiveJob::Temporal::AuditLog).to receive(:record)
      allow(ActiveJob::Temporal::Observability).to receive(:emit)
    end

    it "enqueues multiple jobs and returns per-job success results" do
      allow(client).to receive(:start_workflow).and_return("first-handle", "second-handle")

      result = enqueuer.enqueue_batch([first_job, second_job])

      expect(result.success?).to be true
      expect(result.success_count).to eq(2)
      expect(result.duplicate_count).to eq(0)
      expect(result.failure_count).to eq(0)
      expect(result.results.map(&:to_h)).to contain_exactly(
        hash_including(
          index: 0,
          job_class: "SimpleJob",
          job_id: "batch-job-1",
          status: :success,
          handle: "first-handle"
        ),
        hash_including(
          index: 1,
          job_class: "ScheduledJob",
          job_id: "batch-job-2",
          status: :success,
          handle: "second-handle"
        )
      )
    end

    it "preserves per-job scheduled times and task queue routing" do
      scheduled_time = 1.hour.from_now
      calls = []

      allow(client).to receive(:start_workflow) do |_klass, payload, **options|
        calls << { payload: payload, options: options }
        "handle-#{calls.length}"
      end
      entries = [
        first_job,
        { job: second_job, scheduled_at: scheduled_time }
      ]

      enqueuer.enqueue_batch(entries)

      expect(calls[0][:options][:task_queue]).to eq("mailers")
      expect(calls[0][:payload][:scheduled_at]).to be_nil
      expect(calls[1][:options][:task_queue]).to eq("reports")
      expect(calls[1][:payload][:scheduled_at]).to eq(scheduled_time.iso8601)
    end

    it "treats due batch scheduled times as immediate" do
      now = Time.utc(2026, 5, 25, 12, 0, 0)
      calls = []

      allow(Time).to receive(:now).and_return(now)
      allow(client).to receive(:start_workflow) do |_klass, payload, **_options|
        calls << payload
        "handle-#{calls.length}"
      end

      enqueuer.enqueue_batch([
                               { job: first_job, scheduled_at: now },
                               { job: second_job, scheduled_at: now - 1 }
                             ])

      expect(calls.map { |payload| payload[:scheduled_at] }).to eq([nil, nil])
    end

    it "reports duplicate jobs per item" do
      error = Class.new(StandardError)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", error)
      call_count = 0

      allow(client).to receive(:start_workflow) do
        call_count += 1
        raise error, "already started" if call_count == 2

        "first-handle"
      end

      result = enqueuer.enqueue_batch([first_job, second_job])

      expect(result.success_count).to eq(1)
      expect(result.duplicate_count).to eq(1)
      expect(result.failure_count).to eq(0)
      expect(result.results[1].status).to eq(:duplicate)
      expect(result.results[1].handle).to be_nil
    end

    it "reports enqueue failures per item without stopping the batch" do
      call_count = 0

      allow(client).to receive(:start_workflow) do
        call_count += 1
        raise StandardError, "connection failed" if call_count == 2

        "first-handle"
      end

      result = enqueuer.enqueue_batch([first_job, second_job])

      expect(result.success?).to be false
      expect(result.success_count).to eq(1)
      expect(result.failure_count).to eq(1)
      expect(result.failures.first.index).to eq(1)
      expect(result.failures.first.error).to be_a(ActiveJob::EnqueueError)
    end

    it "validates all inputs before starting any workflows" do
      blank_queue_job = SimpleJob.new
      blank_queue_job.job_id = "blank-queue"
      blank_queue_job.queue_name = nil
      entries = [
        first_job,
        { job: second_job, scheduled_at: "not-a-date" },
        blank_queue_job,
        Object.new
      ]

      expect do
        enqueuer.enqueue_batch(entries)
      end.to raise_error(ActiveJob::Temporal::BatchEnqueueValidationError) { |error|
        expect(error.errors.map { |entry| entry[:index] }).to eq([1, 2, 3])
        expect(error.message).to include("scheduled_at must be")
        expect(error.message).to include("queue name cannot be blank")
        expect(error.message).to include("ActiveJob instance")
      }

      expect(client).not_to have_received(:start_workflow)
    end

    it "rejects invalid concurrency limits" do
      expect do
        enqueuer.enqueue_batch([first_job], concurrency: 0)
      end.to raise_error(ArgumentError, /concurrency must be a positive integer/)

      expect(client).not_to have_received(:start_workflow)
    end

    it "enqueues all jobs when concurrency is greater than one" do
      result = enqueuer.enqueue_batch([first_job, second_job], concurrency: 2)

      expect(result.success_count).to eq(2)
      expect(client).to have_received(:start_workflow).twice
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

RSpec.describe ActiveJob::Temporal do
  describe ".enqueue_batch" do
    it "delegates to a workflow enqueuer with the current client and configuration" do
      configuration = ActiveJob::Temporal::Configuration.new
      configuration.target = "localhost:7233"
      configuration.namespace = "default"
      enqueuer = instance_double(ActiveJob::Temporal::WorkflowEnqueuer)
      items = [SimpleJob.new]
      result = ActiveJob::Temporal::BatchEnqueueResult.new([])

      allow(described_class).to receive(:client).and_return("client")
      allow(described_class).to receive(:config).and_return(configuration)
      allow(ActiveJob::Temporal::WorkflowEnqueuer).to receive(:new)
        .with(instance_of(Proc), configuration, configuration.logger)
        .and_return(enqueuer)
      allow(enqueuer).to receive(:enqueue_batch)
        .with(items, concurrency: 3)
        .and_return(result)

      expect(described_class.enqueue_batch(items, concurrency: 3)).to be(result)
    end
  end
end
