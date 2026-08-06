# frozen_string_literal: true

require "spec_helper"
require "base64"
require_relative "../../fixtures/sample_jobs"
require "activejob/temporal/activities/aj_runner_activity"
require "activejob/temporal/observability/prometheus"

module AjRunnerActivitySpecSupport
  ActivityInfo = Struct.new(:workflow_id, :workflow_namespace, :attempt, keyword_init: true)
  ActivityContext = Struct.new(:info, keyword_init: true)
end

describe ActiveJob::Temporal::Activities::AjRunnerActivity do
  let(:activity) { described_class.new }

  let(:workflow_id) { "wf-123" }
  let(:workflow_namespace) { "test-namespace" }
  let(:activity_info) do
    AjRunnerActivitySpecSupport::ActivityInfo.new(
      workflow_id: workflow_id,
      workflow_namespace: workflow_namespace,
      attempt: 1
    )
  end
  let(:activity_context) { AjRunnerActivitySpecSupport::ActivityContext.new(info: activity_info) }
  let(:args) { [42, "payload"] }
  let(:idempotency_key) { :aj_temporal_idempotency_key }
  let(:middleware_chain) { ActiveJob::Temporal::Middleware::Chain.new }

  before do
    ActiveJob::Temporal.config.payload_serializer = :json
    ActiveJob::Temporal.config.encrypt_payload = false
    ActiveJob::Temporal.config.encryption_key = nil
    ActiveJob::Temporal.config.encryption_old_keys = []

    call_recorded_method(Temporalio::Activity::Context, :exist?, returns: true)
    call_recorded_method(Temporalio::Activity::Context, :current, returns: activity_context)
    call_recorded_method(ActiveJob::Temporal.config, :middleware_chain, returns: middleware_chain)

    @discard_exception_handler = proc { false }
    @discard_exception_recorder =
      call_recorded_method(ActiveJob::Temporal::RetryMapper, :discard_exception?) do |*call_args|
        @discard_exception_handler.call(*call_args)
      end

    original_instrument = ActiveJob::Temporal::Observability.method(:instrument)
    @instrument_handler = proc do |event_name, attributes, &block|
      original_instrument.call(event_name, attributes, &block)
    end
    @instrument_recorder = call_recorded_method(ActiveJob::Temporal::Observability, :instrument) do |*call_args, &block|
      @instrument_handler.call(*call_args, &block)
    end

    original_emit = ActiveJob::Temporal::Observability.method(:emit)
    @emit_handler = proc { |*call_args| original_emit.call(*call_args) }
    @emit_recorder = call_recorded_method(ActiveJob::Temporal::Observability, :emit) do |*call_args|
      @emit_handler.call(*call_args)
    end

    @audit_record_handler = proc {}
    @audit_record_recorder = call_recorded_method(ActiveJob::Temporal::AuditLog, :record) do |*call_args|
      @audit_record_handler.call(*call_args)
    end

    @logger_warn_recorder = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
    @delete_external_payload_recorder =
      call_recorded_method(ActiveJob::Temporal::Payload, :delete_external_payload)
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

      assert_equal "performed", activity.execute(payload)

      assert_equal args, job_class.received_args
      assert_equal "#{workflow_id}/runner", job_class.thread_key
      assert_equal "#{workflow_id}/runner", job_class.fiber_key
      assert_nil Thread.current[idempotency_key]
      assert_nil Fiber[idempotency_key]
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

      assert_equal ["#{workflow_id}/runner", nil], captured_keys
      assert_nil Fiber[idempotency_key]
    end

    it "deserializes payloads with workflow encryption context" do
      job_class = stub_const("ContextRunnerJob", Class.new(ActiveJob::Base) do
        def perform
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)
      encryption_context = { namespace: workflow_namespace, workflow_id: workflow_id }
      expected_context = encryption_context

      deserialize_recorder =
        call_recorded_method(ActiveJob::Temporal::Payload, :deserialize_payload) do |actual_payload, **keywords|
          assert_equal payload, actual_payload
          assert_equal expected_context, keywords.fetch(:encryption_context)

          payload
        end

      assert_equal "performed", activity.execute(payload)
      assert_equal 1, deserialize_recorder.calls_for(:deserialize_payload).size
    end

    it "deserializes scheduled payloads with the schedule encryption context" do
      job_class = stub_const("ScheduleContextRunnerJob", Class.new(ActiveJob::Base) do
        def perform
          "performed"
        end
      end)
      activity_info.workflow_id = "ajschwf:daily-report-2024-01-01T12:00:00Z"
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new).merge(
        schedule_id: "ajsch:daily-report",
        schedule_workflow_id_prefix: "ajschwf:daily-report",
        payload_encryption_context: { namespace: "attacker", workflow_id: "attacker-workflow" }
      )

      expected_context = { namespace: workflow_namespace, workflow_id: "ajschwf:daily-report" }
      deserialize_recorder =
        call_recorded_method(ActiveJob::Temporal::Payload, :deserialize_payload) do |actual_payload, **keywords|
          assert_equal payload, actual_payload
          assert_equal expected_context, keywords.fetch(:encryption_context)

          payload
        end

      assert_equal "performed", activity.execute(payload)
      assert_equal 1, deserialize_recorder.calls_for(:deserialize_payload).size
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
      activity_info.workflow_id = execution_job_id
      payload = ActiveJob::Temporal::Payload.from_job(job).merge(
        schedule_id: "ajsch:daily-report",
        schedule_workflow_id_prefix: "ajschwf:daily-report",
        schedule_execution_job_id: execution_job_id
      )

      activity.execute(payload)

      assert_equal(
        {
          job_id: execution_job_id,
          provider_job_id: execution_job_id,
          idempotency_key: "#{execution_job_id}/runner"
        },
        job_class.performed
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

      assert_equal "performed", activity.execute(payload, raw_arguments)
      assert_equal raw_arguments, job_class.received_args
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
      activity.execute(payload)

      assert_equal(
        [
          [:before, "original-job-id", ["payload"]],
          [:around_before],
          [:perform, "payload", "original-job-id", "provider-job-id", "critical", 7, "en", "UTC"],
          [:after, "original-job-id"],
          [:around_after]
        ],
        events
      )
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

      assert_equal "tenant-42", job_class.tenant_seen
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

      error = assert_raises(Temporalio::Error::ApplicationError) { activity.execute(payload) }

      assert error.retryable?
      assert_equal "RuntimeRetryTimeoutError", error.type
      assert_equal 17.0, error.next_retry_delay
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
      activity_info.attempt = 2

      error = assert_raises(Temporalio::Error::ApplicationError) { activity.execute(payload) }

      assert error.non_retryable
      assert_equal "RuntimeRetryStandardError", error.type
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
      activity_info.attempt = 2

      error = assert_raises(DeadLetterRuntimeRetryError) { activity.execute(payload) }

      assert_equal "standard failure", error.message
    end

    it "re-raises exceptions without ActiveJob retry handlers so Temporal can retry" do
      error = SampleJobError.new("boom")
      job_class = stub_const("PlainFailureRunnerJob", Class.new(ActiveJob::Base) do
        define_method(:perform) do
          raise error
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)

      raised_error = assert_raises(error.class) { activity.execute(payload) }

      assert_same error, raised_error
      assert_nil Thread.current[idempotency_key]
      assert_called_with @discard_exception_recorder, :discard_exception?, job_class, error
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

      assert_equal "performed", activity.execute(payload)
      assert_equal :before, events[0][0]
      assert_kind_of job_class, events[0][1]
      assert_equal "#{workflow_id}/runner", events[0][2]
      assert_equal(
        [
          [:perform, args],
          [:after, "performed"]
        ],
        events[1..]
      )
    end

    it "records job execution observability around perform" do
      job_class = stub_const("MetricsRunnerJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        def perform
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)

      assert_equal "performed", activity.execute(payload)

      assert_instrumented :perform, job_class: "MetricsRunnerJob", queue: "critical"
    end

    it "returns the job result when observability fails after perform succeeds" do
      job_class = stub_const("PostPerformObservabilityJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        def perform
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)
      @instrument_handler = proc do |_event_name, _attributes, &block|
        block.call
        raise StandardError, "metrics down"
      end

      assert_equal "performed", activity.execute(payload)

      assert_warned(
        "activity_post_perform_side_effect_failed",
        side_effect: "observability",
        job_class: "PostPerformObservabilityJob",
        queue: "critical",
        error_class: "StandardError"
      )
      assert_audit_recorded(
        "job.completed",
        job_class: "PostPerformObservabilityJob"
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
      @audit_record_handler = proc do |event_name, *_arguments|
        raise StandardError, "audit down" if event_name == "job.completed"
      end

      assert_equal "performed", activity.execute(payload)

      refute_audit_recorded "job.failed"
      assert_warned(
        "activity_post_perform_side_effect_failed",
        side_effect: "audit",
        job_class: "PostPerformAuditJob",
        error_class: "StandardError"
      )
    end

    it "deletes external payloads after successful perform" do
      job_class = stub_const("ExternalPayloadRunnerJob", Class.new(ActiveJob::Base) do
        def perform
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)

      assert_equal "performed", activity.execute(payload)
      assert_called_with @delete_external_payload_recorder, :delete_external_payload, payload
    end

    it "returns the job result when external payload cleanup fails after perform succeeds" do
      job_class = stub_const("ExternalPayloadCleanupJob", Class.new(ActiveJob::Base) do
        def perform
          "performed"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)
      @delete_external_payload_recorder = call_recorded_method(
        ActiveJob::Temporal::Payload,
        :delete_external_payload,
        raises: StandardError.new("delete down")
      )

      assert_equal "performed", activity.execute(payload)

      assert_warned(
        "activity_post_perform_side_effect_failed",
        side_effect: "external_payload_cleanup",
        job_class: "ExternalPayloadCleanupJob",
        error_class: "StandardError"
      )
    end

    it "keeps external payloads when perform fails" do
      job_class = stub_const("ExternalPayloadFailureRunnerJob", Class.new(ActiveJob::Base) do
        def perform
          raise SampleJobError, "boom"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)

      assert_raises(SampleJobError) { activity.execute(payload) }
      assert_empty @delete_external_payload_recorder.calls_for(:delete_external_payload)
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
        encrypted_payload = ActiveJob::Temporal::Payload.from_job(
          job,
          encryption_context: { namespace: workflow_namespace, workflow_id: workflow_id }
        )
        original_deserialize_payload = ActiveJob::Temporal::Payload.method(:deserialize_payload)
        deserialize_recorder = call_recorded_method(ActiveJob::Temporal::Payload, :deserialize_payload) do |*call_args,
                                                                                                            **keywords|
          original_deserialize_payload.call(*call_args, **keywords)
        end

        assert_equal "performed", activity.execute(encrypted_payload)

        assert_equal 1, deserialize_recorder.calls_for(:deserialize_payload).size
        assert_equal args, job_class.received_args
        assert_instrumented :perform, job_class: "EncryptedRunnerJob", job_id: job.job_id, queue: "default"
        assert_audit_recorded(
          "job.started",
          job_class: "EncryptedRunnerJob",
          job_id: job.job_id,
          queue: "default"
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

      assert_equal "performed", activity.execute(payload)

      assert_equal args, job_class.received_args
      assert_instrumented :perform, job_class: "SerializedRunnerJob", job_id: job.job_id, queue: "default"
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

      assert_equal "secret-result", activity.execute(payload)

      assert_audit_recorded(
        "job.started",
        job_class: "AuditRunnerJob",
        job_id: "job-1",
        queue: "critical",
        workflow_id: workflow_id
      )
      completed_attributes = assert_audit_recorded(
        "job.completed",
        job_class: "AuditRunnerJob",
        job_id: "job-1",
        queue: "critical"
      )
      assert_kind_of Numeric, completed_attributes[:duration_ms]
      refute completed_attributes.key?(:arguments)
      refute completed_attributes.key?(:result)
    end

    it "records failed metrics for setup failures before perform starts" do
      stub_const("SetupFailureJob", Class.new(ActiveJob::Base))
      payload = { "job_class" => "SetupFailureJob", "queue_name" => "critical" }
      error = ArgumentError.new("bad payload")
      adapter = ActiveJob::Temporal.config.observability.use(:prometheus)
      call_recorded_method(ActiveJob::Base, :deserialize, raises: error)

      raised_error = assert_raises(error.class) { activity.execute(payload) }

      assert_same error, raised_error
      assert_includes(
        adapter.render,
        'activejob_temporal_jobs_failed_total{class="SetupFailureJob",queue="critical",error="ArgumentError"} 1.0'
      )
    ensure
      ActiveJob::Temporal::Observability.reset!
    end

    it "wraps payload deserialization failures in non-retryable ApplicationError" do
      payload = { "job_class" => "UndeserializableJob", "queue_name" => "critical" }
      original_error = ActiveJob::SerializationError.new("bad payload")
      expected_context = { namespace: workflow_namespace, workflow_id: workflow_id }
      call_recorded_method(ActiveJob::Temporal::Payload, :deserialize_payload) do |actual_payload, encryption_context:|
        assert_equal payload, actual_payload
        assert_equal expected_context, encryption_context

        raise original_error
      end

      error = assert_raises(Temporalio::Error::ApplicationError) { activity.execute(payload) }

      assert_equal true, error.non_retryable
      assert_equal original_error.message, error.message
      assert_empty @discard_exception_recorder.calls_for(:discard_exception?)
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

      assert_raises(SampleJobError) { activity.execute(payload) }

      failed_attributes = assert_audit_recorded(
        "job.failed",
        job_class: "AuditFailureRunnerJob",
        job_id: "job-1",
        queue: "critical",
        error_class: "SampleJobError"
      )
      assert_match(/\A[0-9a-f]{64}\z/, failed_attributes[:error_fingerprint])
      assert_kind_of Numeric, failed_attributes[:duration_ms]
      refute failed_attributes.key?(:error_message)
      refute failed_attributes.key?(:backtrace)
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
      @audit_record_handler = proc do |event_name, *_arguments|
        raise StandardError, "audit down" if event_name == "job.failed"
      end

      raised_error = assert_raises(error.class) { activity.execute(payload) }

      assert_same error, raised_error
      assert_warned(
        "activity_failure_side_effect_failed",
        side_effect: "audit",
        job_class: "AuditSideEffectFailureRunnerJob",
        error_class: "StandardError"
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

      assert_raises(Temporalio::Error::CanceledError) { activity.execute(payload) }

      assert_audit_recorded(
        "job.cancelled",
        job_class: "CancelledRunnerJob",
        job_id: "job-1",
        queue: "critical",
        status: "observed"
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

      raised_error = assert_raises(error.class) { activity.execute(payload) }

      assert_same error, raised_error
      assert_nil job_class.performed
      assert_called_with @discard_exception_recorder, :discard_exception?, job_class, error
      assert_nil Thread.current[idempotency_key]
    end

    it "records retry observability for retry attempts that fail" do
      activity_info.attempt = 2
      job_class = stub_const("RetryObservabilityRunnerJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        def perform
          raise SampleJobError, "boom"
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)

      assert_raises(SampleJobError) { activity.execute(payload) }

      assert_emitted :retry, job_class: "RetryObservabilityRunnerJob", queue: "critical", error: "SampleJobError"
    end

    it "propagates the original job error when retry observability fails" do
      activity_info.attempt = 2
      error = SampleJobError.new("boom")
      job_class = stub_const("RetryObservabilityFailureRunnerJob", Class.new(ActiveJob::Base) do
        queue_as :critical

        define_method(:perform) do
          raise error
        end
      end)
      payload = ActiveJob::Temporal::Payload.from_job(job_class.new)
      @emit_handler = proc do |event_name, *_arguments|
        raise StandardError, "metrics down" if event_name == :retry
      end

      raised_error = assert_raises(error.class) { activity.execute(payload) }

      assert_same error, raised_error
      assert_warned(
        "activity_failure_side_effect_failed",
        side_effect: "retry_observability",
        job_class: "RetryObservabilityFailureRunnerJob",
        error_class: "StandardError"
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
      @discard_exception_handler = proc do |actual_job_class, error|
        actual_job_class == job_class && error.is_a?(FatalJobError)
      end

      error = assert_raises(Temporalio::Error::ApplicationError) { activity.execute(payload) }

      assert error.non_retryable
      assert_equal "FatalJobError", error.type
      assert_includes error.message, "fail fast"
      assert_kind_of FatalJobError, job_class.discarded_error
      assert_nil Thread.current[idempotency_key]
    end
  end

  def assert_instrumented(event_name, expected_attributes)
    assert_recorded_call(@instrument_recorder, :instrument, event_name, expected_attributes)
  end

  def assert_emitted(event_name, expected_attributes)
    assert_recorded_call(@emit_recorder, :emit, event_name, expected_attributes)
  end

  def assert_audit_recorded(event_name, expected_attributes)
    assert_recorded_call(@audit_record_recorder, :record, event_name, expected_attributes)
  end

  def refute_audit_recorded(event_name)
    matching_calls = @audit_record_recorder.calls_for(:record).select do |recorded_call|
      recorded_call.arguments.first == event_name
    end

    assert_empty matching_calls, "Expected no audit record for #{event_name.inspect}"
  end

  def assert_warned(event_name, expected_attributes)
    assert_recorded_call(@logger_warn_recorder, :warn, event_name, expected_attributes)
  end

  def assert_recorded_call(recorder, method_name, event_name, expected_attributes)
    matching_call = recorder.calls_for(method_name).find do |recorded_call|
      recorded_call.arguments.first == event_name &&
        expected_attributes.all? { |key, value| recorded_call.arguments[1][key] == value }
    end

    refute_nil matching_call, "Expected #{method_name} #{event_name.inspect} with #{expected_attributes.inspect}"

    attributes = matching_call.arguments[1]
    assert_hash_includes expected_attributes, attributes
    attributes
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
