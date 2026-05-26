# frozen_string_literal: true

require "spec_helper"
require "base64"
require_relative "../../fixtures/sample_jobs"
require "activejob/temporal/activities/aj_runner_activity"
require "activejob/temporal/observability/prometheus"

RSpec.describe ActiveJob::Temporal::Activities::AjRunnerActivity do
  subject(:activity) { described_class.new }

  let(:workflow_id) { "wf-123" }
  let(:workflow_namespace) { "test-namespace" }
  let(:activity_info) do
    instance_double(
      "Temporalio::Activity::Info",
      workflow_id: workflow_id,
      workflow_namespace: workflow_namespace,
      attempt: 1
    )
  end
  let(:activity_context) { instance_double("Temporalio::Activity::Context", info: activity_info) }
  let(:args) { [42, "payload"] }
  let(:idempotency_key) { :aj_temporal_idempotency_key }
  let(:middleware_chain) { ActiveJob::Temporal::Middleware::Chain.new }

  before do
    ActiveJob::Temporal.config.payload_serializer = :json
    ActiveJob::Temporal.config.encrypt_payload = false
    ActiveJob::Temporal.config.encryption_key = nil
    ActiveJob::Temporal.config.encryption_old_keys = []
    allow(Temporalio::Activity::Context).to receive(:exist?).and_return(true)
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity_context)
    allow(ActiveJob::Temporal::RetryMapper).to receive(:discard_exception?).and_return(false)
    allow(ActiveJob::Temporal.config).to receive(:middleware_chain).and_return(middleware_chain)
    allow(ActiveJob::Temporal::Observability).to receive(:instrument).and_call_original
    allow(ActiveJob::Temporal::Observability).to receive(:emit).and_call_original
    allow(ActiveJob::Temporal::AuditLog).to receive(:record)
  end

  describe "#execute" do
    it "instantiates the job, performs with deserialized args, and resets idempotency key" do
      idempotency_key_name = idempotency_key
      job_class = stub_const("RunnerSpecJob", Class.new(ActiveJob::Base) do
        class << self
          attr_accessor :received_args, :thread_key, :fiber_key
        end

        define_method(:perform) do |*received_args|
          self.class.received_args = received_args
          self.class.thread_key = Thread.current[idempotency_key_name]
          self.class.fiber_key = Fiber[idempotency_key_name]
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new(*args))

      expect(activity.execute(payload)).to eq("performed")

      expect(job_class.received_args).to eq(args)
      expect(job_class.thread_key).to eq("#{workflow_id}/runner")
      expect(job_class.fiber_key).to eq("#{workflow_id}/runner")
      expect(Thread.current[idempotency_key]).to be_nil
      expect(Fiber[idempotency_key]).to be_nil
    end

    it "makes the idempotency key available to child fibers" do
      captured_keys = []
      idempotency_key_name = idempotency_key
      job_class = stub_const("FiberRunnerJob", Class.new(ActiveJob::Base) do
        define_method(:perform) do
          Fiber.new do
            captured_keys << Fiber[idempotency_key_name]
            captured_keys << Thread.current[idempotency_key_name]
          end.resume
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)

      activity.execute(payload)

      expect(captured_keys).to eq(["#{workflow_id}/runner", nil])
      expect(Fiber[idempotency_key]).to be_nil
    end

    it "deserializes payloads with workflow encryption context" do
      job_class = stub_const("ContextRunnerJob", Class.new(ActiveJob::Base) do
        def perform
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)
      encryption_context = { namespace: workflow_namespace, workflow_id: workflow_id }

      expect(ActiveJob::Temporal::Payload).to receive(:deserialize_payload)
        .with(payload, encryption_context: encryption_context)
        .and_return(payload)

      expect(activity.execute(payload)).to eq("performed")
    end

    it "deserializes scheduled payloads with the schedule encryption context" do
      job_class = stub_const("ScheduleContextRunnerJob", Class.new(ActiveJob::Base) do
        def perform
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new).merge(
        payload_encryption_context: { namespace: "default", workflow_id: "ajschwf:daily-report" }
      )

      expect(ActiveJob::Temporal::Payload).to receive(:deserialize_payload)
        .with(payload, encryption_context: { namespace: "default", workflow_id: "ajschwf:daily-report" })
        .and_return(payload)

      expect(activity.execute(payload)).to eq("performed")
    end

    it "uses the scheduled workflow occurrence ID as the ActiveJob execution identity" do
      idempotency_key_name = idempotency_key
      job_class = stub_const("ScheduleIdentityRunnerJob", Class.new(ActiveJob::Base) do
        class << self
          attr_accessor :performed
        end

        define_method(:perform) do
          self.class.performed = {
            job_id: job_id,
            provider_job_id: provider_job_id,
            idempotency_key: Thread.current[idempotency_key_name]
          }
        end
      end)
      job = job_class.new
      job.job_id = "ajsch:daily-report"
      execution_job_id = "ajschwf:daily-report-2024-01-01T12:00:00Z"
      allow(activity_info).to receive(:workflow_id).and_return(execution_job_id)
      payload = ActiveJob::Temporal::Payload.from_job(job).merge(
        schedule_id: "ajsch:daily-report",
        schedule_workflow_id_prefix: "ajschwf:daily-report",
        schedule_execution_job_id: execution_job_id
      )

      activity.execute(payload)

      expect(job_class.performed).to eq(
        job_id: execution_job_id,
        provider_job_id: execution_job_id,
        idempotency_key: "#{execution_job_id}/runner"
      )
    end

    it "uses optional raw arguments instead of deserializing payload arguments" do
      raw_arguments = ["previous-result"]
      job_class = stub_const("RawOverrideRunnerJob", Class.new(ActiveJob::Base) do
        class << self
          attr_accessor :received_args
        end

        def perform(*received_args)
          self.class.received_args = received_args
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new("serialized"))

      expect(activity.execute(payload, raw_arguments)).to eq("performed")
      expect(job_class.received_args).to eq(raw_arguments)
    end

    it "executes the deserialized job through ActiveJob callbacks with restored state" do
      events = []
      job_class = stub_const("LifecycleRunnerJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        before_perform { |job| events << [:before, job.job_id, job.arguments] }
        around_perform do |_job, block|
          events << [:around_before]
          block.call
          events << [:around_after]
        end
        after_perform { |job| events << [:after, job.job_id] }

        def perform(value)
          self.class.events << [
            :perform,
            value,
            job_id,
            provider_job_id,
            queue_name,
            priority,
            locale,
            timezone
          ]
        end

        class << self
          attr_accessor :events
        end
      end)
      job_class.events = events
      job = job_class.new("payload")
      job.job_id = "original-job-id"
      job.provider_job_id = "provider-job-id"
      job.priority = 7
      job.locale = "en"
      job.timezone = "UTC"
      payload = ActiveJob::Temporal::Payload.from_job(job)
      allow(ActiveJob::Temporal::Payload).to receive(:deserialize_payload_args).and_call_original

      activity.execute(payload)

      expect(events).to eq([
                             [:before, "original-job-id", ["payload"]],
                             [:around_before],
                             [:perform, "payload", "original-job-id", "provider-job-id", "critical", 7, "en", "UTC"],
                             [:after, "original-job-id"],
                             [:around_after]
                           ])
    end

    it "uses custom ActiveJob deserialization before performing" do
      job_class = stub_const("CustomDeserializeRunnerJob", Class.new(ActiveJob::Base) do
        attr_accessor :tenant

        def serialize
          super.merge("tenant" => tenant)
        end

        def deserialize(job_data)
          super
          self.tenant = job_data.fetch("tenant")
        end

        def perform
          self.class.tenant_seen = tenant
        end

        class << self
          attr_accessor :tenant_seen
        end
      end)
      job = job_class.new
      job.tenant = "tenant-42"
      payload = ActiveJob::Temporal::Payload.from_job(job)

      activity.execute(payload)

      expect(job_class.tenant_seen).to eq("tenant-42")
    end

    it "raises a retryable application error when retry_on requests another attempt" do
      error_class = stub_const("RuntimeRetryTimeoutError", Class.new(StandardError))
      job_class = stub_const("RuntimeRetryRunnerJob", Class.new(ActiveJob::Base) do
        retry_on StandardError, wait: 11.seconds, attempts: 2
        retry_on RuntimeRetryTimeoutError, wait: 17.seconds, attempts: 6

        def perform
          raise self.class.error_to_raise
        end

        class << self
          attr_accessor :error_to_raise
        end
      end)
      job_class.error_to_raise = error_class.new("timeout")
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)

      expect { activity.execute(payload) }
        .to raise_error(Temporalio::Error::ApplicationError) do |error|
          expect(error.retryable?).to be(true)
          expect(error.type).to eq("RuntimeRetryTimeoutError")
          expect(error.next_retry_delay).to eq(17.0)
        end
    end

    it "stops Temporal retries when the matching retry_on attempts are exhausted" do
      stub_const("RuntimeRetryStandardError", Class.new(StandardError))
      job_class = stub_const("RuntimeRetryExhaustedJob", Class.new(ActiveJob::Base) do
        retry_on RuntimeRetryStandardError, wait: 11.seconds, attempts: 2
        retry_on NetworkTimeoutError, wait: 17.seconds, attempts: 6

        def perform
          raise RuntimeRetryStandardError, "standard failure"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)
      retry_activity_info = instance_double(
        "Temporalio::Activity::Info",
        workflow_id: workflow_id,
        workflow_namespace: workflow_namespace,
        attempt: 2
      )
      allow(Temporalio::Activity::Context).to receive(:current)
        .and_return(instance_double("Temporalio::Activity::Context", info: retry_activity_info))

      expect { activity.execute(payload) }
        .to raise_error(Temporalio::Error::ApplicationError) do |error|
          expect(error.non_retryable).to be(true)
          expect(error.type).to eq("RuntimeRetryStandardError")
        end
    end

    it "lets Temporal mark DLQ-enabled exhausted retry_on attempts as maximum attempts reached" do
      stub_const("DeadLetterRuntimeRetryError", Class.new(StandardError))
      job_class = stub_const("DeadLetterRuntimeRetryJob", Class.new(ActiveJob::Base) do
        retry_on DeadLetterRuntimeRetryError, wait: 1.second, attempts: 2

        def perform
          raise DeadLetterRuntimeRetryError, "standard failure"
        end
      end)
      job = job_class.new
      payload = ActiveJob::Temporal::Payload.from_job(job)
      payload[:dead_letter] = {
        queue: "failed_jobs",
        job_class: "DeadLetterRuntimeRetryJob",
        job_id: job.job_id,
        after_attempts: 2
      }
      retry_activity_info = instance_double(
        "Temporalio::Activity::Info",
        workflow_id: workflow_id,
        workflow_namespace: workflow_namespace,
        attempt: 2
      )
      allow(Temporalio::Activity::Context).to receive(:current)
        .and_return(instance_double("Temporalio::Activity::Context", info: retry_activity_info))

      expect { activity.execute(payload) }
        .to raise_error(DeadLetterRuntimeRetryError, "standard failure")
    end

    it "re-raises exceptions without ActiveJob retry handlers so Temporal can retry" do
      error = SampleJobError.new("boom")
      job_class = stub_const("PlainFailureRunnerJob", Class.new(ActiveJob::Base) do
        define_method(:perform) do
          raise error
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)

      expect do
        activity.execute(payload)
      end.to raise_error(error)

      expect(Thread.current[idempotency_key]).to be_nil
      expect(ActiveJob::Temporal::RetryMapper).to have_received(:discard_exception?).with(job_class, error)
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
      job_class = stub_const("MiddlewareRunnerJob", Class.new(ActiveJob::Base) do
        define_method(:perform) do |*received_args|
          events << [:perform, received_args]
          "performed"
        end
      end)
      job = job_class.new(*args)
      payload = ActiveJob::Temporal::Payload.from_job(job)

      expect(activity.execute(payload)).to eq("performed")
      expect(events[0][0]).to eq(:before)
      expect(events[0][1]).to be_a(job_class)
      expect(events[0][2]).to eq("#{workflow_id}/runner")
      expect(events[1..]).to eq([
                                  [:perform, args],
                                  [:after, "performed"]
                                ])
    end

    it "records job execution observability around perform" do
      job_class = stub_const("MetricsRunnerJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        def perform
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)

      expect(activity.execute(payload)).to eq("performed")

      expect(ActiveJob::Temporal::Observability).to have_received(:instrument).with(
        :perform,
        hash_including(job_class: "MetricsRunnerJob", queue: "critical")
      )
    end

    it "returns the job result when observability fails after perform succeeds" do
      job_class = stub_const("PostPerformObservabilityJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        def perform
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      allow(ActiveJob::Temporal::Observability).to receive(:instrument) do |_event_name, _attributes, &block|
        block.call
        raise StandardError, "metrics down"
      end

      expect(activity.execute(payload)).to eq("performed")

      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "activity_post_perform_side_effect_failed",
        hash_including(
          side_effect: "observability",
          job_class: "PostPerformObservabilityJob",
          queue: "critical",
          error_class: "StandardError"
        )
      )
      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.completed",
        hash_including(job_class: "PostPerformObservabilityJob")
      )
    end

    it "returns the job result when completed audit fails after perform succeeds" do
      job_class = stub_const("PostPerformAuditJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        def perform
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      allow(ActiveJob::Temporal::AuditLog).to receive(:record) do |event_name, *_arguments|
        raise StandardError, "audit down" if event_name == "job.completed"
      end

      expect(activity.execute(payload)).to eq("performed")

      expect(ActiveJob::Temporal::AuditLog).not_to have_received(:record).with(
        "job.failed",
        anything
      )
      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "activity_post_perform_side_effect_failed",
        hash_including(side_effect: "audit", job_class: "PostPerformAuditJob", error_class: "StandardError")
      )
    end

    it "deletes external payloads after successful perform" do
      job_class = stub_const("ExternalPayloadRunnerJob", Class.new(ActiveJob::Base) do
        def perform
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)

      expect(ActiveJob::Temporal::Payload).to receive(:delete_external_payload).with(payload)

      expect(activity.execute(payload)).to eq("performed")
    end

    it "returns the job result when external payload cleanup fails after perform succeeds" do
      job_class = stub_const("ExternalPayloadCleanupJob", Class.new(ActiveJob::Base) do
        def perform
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)
      allow(ActiveJob::Temporal::Payload).to receive(:delete_external_payload).and_raise(StandardError, "delete down")
      allow(ActiveJob::Temporal::Logger).to receive(:warn)

      expect(activity.execute(payload)).to eq("performed")

      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "activity_post_perform_side_effect_failed",
        hash_including(
          side_effect: "external_payload_cleanup",
          job_class: "ExternalPayloadCleanupJob",
          error_class: "StandardError"
        )
      )
    end

    it "keeps external payloads when perform fails" do
      job_class = stub_const("ExternalPayloadFailureRunnerJob", Class.new(ActiveJob::Base) do
        def perform
          raise SampleJobError, "boom"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)

      expect(ActiveJob::Temporal::Payload).not_to receive(:delete_external_payload)

      expect { activity.execute(payload) }.to raise_error(SampleJobError)
    end

    it "decrypts encrypted payloads before metrics, audit, and job execution" do
      job_class = stub_const("EncryptedRunnerJob", Class.new(ActiveJob::Base) do
        class << self
          attr_accessor :received_args
        end

        def perform(*received_args)
          self.class.received_args = received_args
          "performed"
        end
      end)
      job = job_class.new(*args)

      with_payload_encryption do
        encrypted_payload = ActiveJob::Temporal::Payload.from_job(job)
        allow(ActiveJob::Temporal::Payload).to receive(:deserialize_payload).and_call_original

        expect(activity.execute(encrypted_payload)).to eq("performed")

        expect(ActiveJob::Temporal::Payload).to have_received(:deserialize_payload).once
        expect(job_class.received_args).to eq(args)
        expect(ActiveJob::Temporal::Observability).to have_received(:instrument).with(
          :perform,
          hash_including(job_class: "EncryptedRunnerJob", job_id: job.job_id, queue: "default")
        )
        expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
          "job.started",
          hash_including(job_class: "EncryptedRunnerJob", job_id: job.job_id, queue: "default")
        )
      end
    end

    it "executes jobs from serialized payload envelopes" do
      job_class = stub_const("SerializedRunnerJob", Class.new(ActiveJob::Base) do
        class << self
          attr_accessor :received_args
        end

        def perform(*received_args)
          self.class.received_args = received_args
          "performed"
        end
      end)
      job = job_class.new(*args)

      ActiveJob::Temporal.config.payload_serializer = :message_pack
      payload = ActiveJob::Temporal::Payload.from_job(job)

      expect(activity.execute(payload)).to eq("performed")

      expect(job_class.received_args).to eq(args)
      expect(ActiveJob::Temporal::Observability).to have_received(:instrument).with(
        :perform,
        hash_including(job_class: "SerializedRunnerJob", job_id: job.job_id, queue: "default")
      )
    ensure
      ActiveJob::Temporal.config.payload_serializer = :json
    end

    it "records started and completed audit events without raw arguments or result" do
      job_class = stub_const("AuditRunnerJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        def perform(_value)
          "secret-result"
        end
      end)
      job = job_class.new("secret")
      job.job_id = "job-1"
      payload = ActiveJob::Temporal::Payload.from_job(job)

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
      stub_const("SetupFailureJob", Class.new(ActiveJob::Base))
      payload = { "job_class" => "SetupFailureJob", "queue_name" => "critical" }
      error = ArgumentError.new("bad payload")
      adapter = ActiveJob::Temporal.config.observability.use(:prometheus)
      allow(ActiveJob::Base).to receive(:deserialize).and_raise(error)

      expect { activity.execute(payload) }.to raise_error(error)

      expect(adapter.render).to include(
        'activejob_temporal_jobs_failed_total{class="SetupFailureJob",queue="critical",error="ArgumentError"} 1.0'
      )
    ensure
      ActiveJob::Temporal::Observability.reset!
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
      job_class = stub_const("AuditFailureRunnerJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        def perform
          raise SampleJobError, "boom"
        end
      end)
      job = job_class.new
      job.job_id = "job-1"
      payload = ActiveJob::Temporal::Payload.from_job(job)

      expect { activity.execute(payload) }.to raise_error(SampleJobError)

      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.failed",
        hash_including(
          job_class: "AuditFailureRunnerJob",
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

    it "propagates the original job error when failed audit recording fails" do
      error = SampleJobError.new("boom")
      job_class = stub_const("AuditSideEffectFailureRunnerJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        define_method(:perform) do
          raise error
        end
      end)
      job = job_class.new
      job.job_id = "job-1"
      payload = ActiveJob::Temporal::Payload.from_job(job)
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      allow(ActiveJob::Temporal::AuditLog).to receive(:record) do |event_name, *_arguments|
        raise StandardError, "audit down" if event_name == "job.failed"
      end

      expect { activity.execute(payload) }.to raise_error(error)

      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "activity_failure_side_effect_failed",
        hash_including(side_effect: "audit", job_class: "AuditSideEffectFailureRunnerJob", error_class: "StandardError")
      )
    end

    it "records cancelled audit events for Temporal cancellation errors" do
      job_class = stub_const("CancelledRunnerJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        def perform
          raise Temporalio::Error::CanceledError, "cancelled"
        end
      end)
      job = job_class.new
      job.job_id = "job-1"
      payload = ActiveJob::Temporal::Payload.from_job(job)

      expect { activity.execute(payload) }.to raise_error(Temporalio::Error::CanceledError)

      expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
        "job.cancelled",
        hash_including(
          job_class: "CancelledRunnerJob",
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
      job_class = stub_const("MiddlewareFailureRunnerJob", Class.new(ActiveJob::Base) do
        class << self
          attr_accessor :performed
        end

        def perform
          self.class.performed = true
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)

      expect { activity.execute(payload) }.to raise_error(error)

      expect(job_class.performed).to be_nil
      expect(ActiveJob::Temporal::RetryMapper).to have_received(:discard_exception?).with(job_class, error)
      expect(Thread.current[idempotency_key]).to be_nil
    end

    it "records retry observability for retry attempts that fail" do
      activity_info = instance_double(
        "Temporalio::Activity::Info",
        workflow_id: workflow_id,
        workflow_namespace: workflow_namespace,
        attempt: 2
      )
      activity_context = instance_double("Temporalio::Activity::Context", info: activity_info)
      allow(Temporalio::Activity::Context).to receive(:current).and_return(activity_context)
      job_class = stub_const("RetryObservabilityRunnerJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        def perform
          raise SampleJobError, "boom"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)

      expect { activity.execute(payload) }.to raise_error(SampleJobError)

      expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
        :retry,
        hash_including(job_class: "RetryObservabilityRunnerJob", queue: "critical", error: "SampleJobError")
      )
    end

    it "propagates the original job error when retry observability fails" do
      retry_activity_info = instance_double(
        "Temporalio::Activity::Info",
        workflow_id: workflow_id,
        workflow_namespace: workflow_namespace,
        attempt: 2
      )
      retry_activity_context = instance_double("Temporalio::Activity::Context", info: retry_activity_info)
      allow(Temporalio::Activity::Context).to receive(:current).and_return(retry_activity_context)
      error = SampleJobError.new("boom")
      job_class = stub_const("RetryObservabilityFailureRunnerJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        define_method(:perform) do
          raise error
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      allow(ActiveJob::Temporal::Observability).to receive(:emit) do |event_name, *_arguments|
        raise StandardError, "metrics down" if event_name == :retry
      end

      expect { activity.execute(payload) }.to raise_error(error)

      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "activity_failure_side_effect_failed",
        hash_including(
          side_effect: "retry_observability",
          job_class: "RetryObservabilityFailureRunnerJob",
          error_class: "StandardError"
        )
      )
    end

    it "runs ActiveJob discard handlers before surfacing discard_on as non-retryable" do
      job_class = stub_const("DiscardHandlerRunnerJob", Class.new(ActiveJob::Base) do
        discard_on FatalJobError

        class << self
          attr_accessor :discarded_error
        end

        after_discard do |_job, error|
          self.class.discarded_error = error
        end

        def perform
          raise FatalJobError, "fail fast"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)
      allow(ActiveJob::Temporal::RetryMapper).to receive(:discard_exception?)
        .with(job_class, instance_of(FatalJobError))
        .and_return(true)

      expect { activity.execute(payload) }
        .to raise_error(Temporalio::Error::ApplicationError) do |error|
          expect(error.non_retryable).to be(true)
          expect(error.type).to eq("FatalJobError")
          expect(error.message).to include("fail fast")
        end

      expect(job_class.discarded_error).to be_a(FatalJobError)
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
