# frozen_string_literal: true

require "spec_helper"
require "base64"
require_relative "../../fixtures/sample_jobs"
require "activejob/temporal/activities/aj_runner_activity"

RSpec.describe ActiveJob::Temporal::Activities::AjRunnerActivity do
  subject(:activity) { described_class.new }

  let(:workflow_id) { "wf-123" }
  let(:workflow_namespace) { "test-namespace" }
  let(:activity_info) do
    instance_double("Temporalio::Activity::Info", workflow_id: workflow_id, workflow_namespace: workflow_namespace)
  end
  let(:activity_context) { instance_double("Temporalio::Activity::Context", info: activity_info) }
  let(:args) { [42, "payload"] }
  let(:idempotency_key) { :aj_temporal_idempotency_key }
  let(:middleware_chain) { ActiveJob::Temporal::Middleware::Chain.new }

  before do
    # Mock the real SDK's Activity Context API
    ActiveJob::Temporal.config.payload_serializer = :json
    allow(Temporalio::Activity::Context).to receive(:exist?).and_return(true)
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity_context)
    allow(ActiveJob::Temporal::Payload).to receive(:deserialize_payload_args).and_return(args)
    allow(ActiveJob::Temporal::RetryMapper).to receive(:discard_exception?).and_return(false)
    allow(ActiveJob::Temporal.config).to receive(:middleware_chain).and_return(middleware_chain)
    allow(ActiveJob::Temporal::Metrics).to receive(:instrument_perform).and_call_original
    allow(ActiveJob::Temporal::Metrics).to receive(:record_retry)
    allow(ActiveJob::Temporal::AuditLog).to receive(:record)
  end

  describe "#execute" do
    it "instantiates the job, performs with deserialized args, and resets idempotency key" do
      job_instance = instance_double("RunnerSpecJob")
      job_class = class_double("RunnerSpecJob", new: job_instance).as_stubbed_const
      payload = { "job_class" => "RunnerSpecJob", "arguments" => ["raw"] }

      expect(ActiveJob::Temporal::Payload).to receive(:deserialize_payload_args).with(payload).and_return(args)
      allow(job_instance).to receive(:perform) do |*received_args|
        expect(Thread.current[idempotency_key]).to eq("#{workflow_id}/runner")
        expect(received_args).to eq(args)
      end

      activity.execute(payload)

      expect(job_class).to have_received(:new)
      expect(job_instance).to have_received(:perform).with(*args)
      expect(Thread.current[idempotency_key]).to be_nil
    end

    it "deserializes payloads with workflow encryption context" do
      job_instance = instance_double("ContextRunnerJob")
      job_class = class_double("ContextRunnerJob", new: job_instance).as_stubbed_const
      payload = { "job_class" => "ContextRunnerJob", "arguments" => ["raw"] }
      encryption_context = { namespace: workflow_namespace, workflow_id: workflow_id }

      expect(ActiveJob::Temporal::Payload).to receive(:deserialize_payload)
        .with(payload, encryption_context: encryption_context)
        .and_return(payload)
      expect(ActiveJob::Temporal::Payload).to receive(:deserialize_payload_args).with(payload).and_return(args)
      allow(job_instance).to receive(:perform).and_return("performed")

      expect(activity.execute(payload)).to eq("performed")

      expect(job_class).to have_received(:new)
    end

    it "uses optional raw arguments instead of deserializing payload arguments" do
      raw_arguments = ["previous-result"]
      job_instance = instance_double("RawOverrideRunnerJob")
      job_class = class_double("RawOverrideRunnerJob", new: job_instance).as_stubbed_const
      payload = { "job_class" => "RawOverrideRunnerJob", "arguments" => ["serialized"] }
      allow(job_instance).to receive(:perform).and_return("performed")

      expect(ActiveJob::Temporal::Payload).not_to receive(:deserialize_payload_args)

      expect(activity.execute(payload, raw_arguments)).to eq("performed")
      expect(job_class).to have_received(:new)
      expect(job_instance).to have_received(:perform).with(*raw_arguments)
    end

    it "re-raises retryable exceptions so Temporal can retry" do
      payload = { "job_class" => "RetryableJob" }
      job_instance = instance_double(RetryableJob.name)
      allow(RetryableJob).to receive(:new).and_return(job_instance)
      error = SampleJobError.new("boom")
      allow(job_instance).to receive(:perform).and_raise(error)

      expect do
        activity.execute(payload)
      end.to raise_error(error)

      expect(Thread.current[idempotency_key]).to be_nil
      expect(ActiveJob::Temporal::RetryMapper).to have_received(:discard_exception?).with(RetryableJob, error)
    end

    it "executes the job through configured middleware" do
      events = []
      middleware_class = Class.new do
        def initialize(events, idempotency_key)
          @events = events
          @idempotency_key = idempotency_key
        end

        def call(job)
          @events << [:before, job, Thread.current[@idempotency_key]]
          result = yield
          @events << [:after, result]
          result
        end
      end
      middleware_chain.add(middleware_class, events, idempotency_key)
      job_instance = instance_double("MiddlewareRunnerJob")
      class_double("MiddlewareRunnerJob", new: job_instance).as_stubbed_const
      payload = { "job_class" => "MiddlewareRunnerJob" }
      allow(job_instance).to receive(:perform) do |*received_args|
        events << [:perform, received_args]
        "performed"
      end

      expect(activity.execute(payload)).to eq("performed")
      expect(events).to eq([
                             [:before, job_instance, "#{workflow_id}/runner"],
                             [:perform, args],
                             [:after, "performed"]
                           ])
    end

    it "records job execution metrics around perform" do
      job_instance = instance_double("MetricsRunnerJob")
      class_double("MetricsRunnerJob", new: job_instance).as_stubbed_const
      payload = { "job_class" => "MetricsRunnerJob", "queue_name" => "critical" }
      allow(job_instance).to receive(:perform).and_return("performed")

      expect(activity.execute(payload)).to eq("performed")

      expect(ActiveJob::Temporal::Metrics).to have_received(:instrument_perform).with(payload)
    end

    it "decrypts encrypted payloads before metrics, audit, and job execution" do
      stub_const("EncryptedRunnerJob", Class.new(ActiveJob::Base))
      job = EncryptedRunnerJob.new(*args)

      with_payload_encryption do
        encrypted_payload = ActiveJob::Temporal::Payload.from_job(job)
        job_instance = instance_double("EncryptedRunnerJob")
        allow(EncryptedRunnerJob).to receive(:new).and_return(job_instance)
        allow(job_instance).to receive(:perform).and_return("performed")
        allow(ActiveJob::Temporal::Payload).to receive(:deserialize_payload_args).and_call_original

        expect(activity.execute(encrypted_payload)).to eq("performed")

        expect(job_instance).to have_received(:perform).with(*args)
        expect(ActiveJob::Temporal::Metrics).to have_received(:instrument_perform).with(
          hash_including(job_class: "EncryptedRunnerJob", job_id: job.job_id, queue_name: "default")
        )
        expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
          "job.started",
          hash_including(job_class: "EncryptedRunnerJob", job_id: job.job_id, queue: "default")
        )
      end
    end

    it "executes jobs from serialized payload envelopes" do
      stub_const("SerializedRunnerJob", Class.new(ActiveJob::Base))
      job = SerializedRunnerJob.new(*args)

      ActiveJob::Temporal.config.payload_serializer = :message_pack
      payload = ActiveJob::Temporal::Payload.from_job(job)
      job_instance = instance_double("SerializedRunnerJob")
      allow(SerializedRunnerJob).to receive(:new).and_return(job_instance)
      allow(job_instance).to receive(:perform).and_return("performed")
      allow(ActiveJob::Temporal::Payload).to receive(:deserialize_payload_args).and_call_original

      expect(activity.execute(payload)).to eq("performed")

      expect(job_instance).to have_received(:perform).with(*args)
      expect(ActiveJob::Temporal::Metrics).to have_received(:instrument_perform).with(
        hash_including(job_class: "SerializedRunnerJob", job_id: job.job_id, queue_name: "default")
      )
    ensure
      ActiveJob::Temporal.config.payload_serializer = :json
    end

    it "records started and completed audit events without raw arguments or result" do
      job_instance = instance_double("AuditRunnerJob")
      class_double("AuditRunnerJob", new: job_instance).as_stubbed_const
      payload = {
        "job_class" => "AuditRunnerJob",
        "job_id" => "job-1",
        "queue_name" => "critical",
        "arguments" => ["secret"]
      }
      allow(job_instance).to receive(:perform).and_return("secret-result")

      expect(activity.execute(payload)).to eq("secret-result")

      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.started",
        hash_including(
          job_class: "AuditRunnerJob",
          job_id: "job-1",
          queue: "critical",
          workflow_id: workflow_id
        )
      )
      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.completed",
        hash_including(
          job_class: "AuditRunnerJob",
          job_id: "job-1",
          queue: "critical",
          duration_ms: a_kind_of(Numeric)
        )
      )
      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.completed",
        satisfy do |attributes|
          !attributes.key?(:arguments) && !attributes.key?(:result)
        end
      )
    end

    it "records failed metrics for setup failures before perform starts" do
      previous_provider = ActiveJob::Temporal.config.metrics_provider
      payload = { "job_class" => "SetupFailureJob", "queue_name" => "critical" }
      error = ArgumentError.new("bad payload")
      ActiveJob::Temporal::Metrics.reset!
      ActiveJob::Temporal.config.metrics_provider = :prometheus
      allow(ActiveJob::Temporal::Payload).to receive(:deserialize_payload_args).with(payload).and_raise(error)

      expect { activity.execute(payload) }.to raise_error(error)

      expect(ActiveJob::Temporal::Metrics.render).to include(
        'activejob_temporal_jobs_failed_total{class="SetupFailureJob",queue="critical",error="ArgumentError"} 1.0'
      )
    ensure
      ActiveJob::Temporal.config.metrics_provider = previous_provider if previous_provider
      ActiveJob::Temporal::Metrics.reset!
    end

    it "wraps payload deserialization failures in non-retryable ApplicationError" do
      payload = { "job_class" => "UndeserializableJob", "queue_name" => "critical" }
      original_error = ActiveJob::SerializationError.new("bad payload")
      allow(ActiveJob::Temporal::Payload).to receive(:deserialize_payload)
        .with(payload, encryption_context: { namespace: workflow_namespace, workflow_id: workflow_id })
        .and_raise(original_error)

      expect { activity.execute(payload) }
        .to raise_error(Temporalio::Error::ApplicationError) do |error|
          expect(error.non_retryable).to eq(true)
          expect(error.message).to eq(original_error.message)
        end

      expect(ActiveJob::Temporal::RetryMapper).not_to have_received(:discard_exception?)
    end

    it "records failed audit events with error metadata" do
      payload = { "job_class" => "RetryableJob", "job_id" => "job-1", "queue_name" => "critical" }
      job_instance = instance_double(RetryableJob.name)
      allow(RetryableJob).to receive(:new).and_return(job_instance)
      error = SampleJobError.new("boom")
      allow(job_instance).to receive(:perform).and_raise(error)

      expect { activity.execute(payload) }.to raise_error(error)

      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.failed",
        hash_including(
          job_class: "RetryableJob",
          job_id: "job-1",
          queue: "critical",
          error_class: "SampleJobError",
          error_fingerprint: a_string_matching(/\A[0-9a-f]{64}\z/),
          duration_ms: a_kind_of(Numeric)
        )
      )
      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.failed",
        satisfy do |attributes|
          !attributes.key?(:error_message) && !attributes.key?(:backtrace)
        end
      )
    end

    it "records cancelled audit events for Temporal cancellation errors" do
      payload = { "job_class" => "RetryableJob", "job_id" => "job-1", "queue_name" => "critical" }
      job_instance = instance_double(RetryableJob.name)
      allow(RetryableJob).to receive(:new).and_return(job_instance)
      error = Temporalio::Error::CanceledError.new("cancelled")
      allow(job_instance).to receive(:perform).and_raise(error)

      expect { activity.execute(payload) }.to raise_error(error)

      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.cancelled",
        hash_including(
          job_class: "RetryableJob",
          job_id: "job-1",
          queue: "critical",
          status: "observed"
        )
      )
    end

    it "routes middleware exceptions through Temporal retry handling" do
      error = RuntimeError.new("middleware failed")
      middleware_class = Class.new do
        def initialize(error)
          @error = error
        end

        def call(_job)
          raise @error
        end
      end
      middleware_chain.add(middleware_class, error)
      payload = { "job_class" => "RetryableJob" }
      job_instance = instance_double(RetryableJob.name)
      allow(RetryableJob).to receive(:new).and_return(job_instance)
      allow(job_instance).to receive(:perform)

      expect { activity.execute(payload) }.to raise_error(error)

      expect(job_instance).not_to have_received(:perform)
      expect(ActiveJob::Temporal::RetryMapper).to have_received(:discard_exception?).with(RetryableJob, error)
      expect(Thread.current[idempotency_key]).to be_nil
    end

    it "records retry metrics for retry attempts that fail" do
      activity_info = instance_double("Temporalio::Activity::Info", workflow_id: workflow_id, attempt: 2)
      activity_context = instance_double("Temporalio::Activity::Context", info: activity_info)
      allow(Temporalio::Activity::Context).to receive(:current).and_return(activity_context)
      payload = { "job_class" => "RetryableJob", "queue_name" => "critical" }
      job_instance = instance_double(RetryableJob.name)
      allow(RetryableJob).to receive(:new).and_return(job_instance)
      error = SampleJobError.new("boom")
      allow(job_instance).to receive(:perform).and_raise(error)

      expect { activity.execute(payload) }.to raise_error(error)

      expect(ActiveJob::Temporal::Metrics).to have_received(:record_retry).with(payload, error)
    end

    it "wraps discard_on exceptions in non-retryable ApplicationError" do
      payload = { "job_class" => "DiscardOnlyJob" }
      job_instance = instance_double(DiscardOnlyJob.name)
      allow(DiscardOnlyJob).to receive(:new).and_return(job_instance)
      original_error = FatalJobError.new("fail fast")
      allow(job_instance).to receive(:perform).and_raise(original_error)
      allow(ActiveJob::Temporal::RetryMapper).to receive(:discard_exception?)
        .with(DiscardOnlyJob, original_error)
        .and_return(true)

      expect { activity.execute(payload) }
        .to raise_error(Temporalio::Error::ApplicationError) do |error|
          expect(error.non_retryable).to eq(true)
          expect(error.message).to eq(original_error.message)
        end

      expect(Thread.current[idempotency_key]).to be_nil
    end
  end

  def with_payload_encryption
    previous_encrypt_payload = ActiveJob::Temporal.config.encrypt_payload
    previous_encryption_key = ActiveJob::Temporal.config.encryption_key
    previous_encryption_old_keys = ActiveJob::Temporal.config.encryption_old_keys

    ActiveJob::Temporal.configure do |config|
      config.encrypt_payload = true
      config.encryption_key = Base64.strict_encode64("activity-key".ljust(32, "-")[0, 32])
      config.encryption_old_keys = []
    end

    yield
  ensure
    ActiveJob::Temporal.configure do |config|
      config.encrypt_payload = previous_encrypt_payload
      config.encryption_key = previous_encryption_key
      config.encryption_old_keys = previous_encryption_old_keys
    end
  end
end
