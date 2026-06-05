# frozen_string_literal: true

require "spec_helper"
require_relative "../fixtures/sample_jobs"

module WorkflowEnqueuerSpecSupport
  class FakeClient
    attr_accessor :start_workflow_error
    attr_reader :start_workflow_calls

    def initialize
      @start_workflow_calls = []
      @start_workflow_results = ["workflow-handle"]
    end

    def start_workflow_results=(results)
      @start_workflow_results = results.dup
    end

    def on_start_workflow(&implementation)
      @start_workflow_implementation = implementation
    end

    def start_workflow(*arguments, **keywords)
      @start_workflow_calls << { arguments: arguments, keywords: keywords }
      return @start_workflow_implementation.call(*arguments, **keywords) if @start_workflow_implementation

      raise start_workflow_error if start_workflow_error

      next_start_workflow_result
    end

    private

    def next_start_workflow_result
      return nil if @start_workflow_results.empty?
      return @start_workflow_results.shift if @start_workflow_results.size > 1

      @start_workflow_results.first
    end
  end

  class FakeWorkflowIdBuilder
    attr_reader :build_calls

    def initialize(workflow_id)
      @workflow_id = workflow_id
      @build_calls = []
    end

    def build(job)
      @build_calls << job
      @workflow_id
    end
  end

  class FakePayloadBuilder
    attr_reader :build_calls

    def initialize(payload)
      @payload = payload
      @build_calls = []
    end

    def build(job, scheduled_at:, encryption_context:)
      @build_calls << {
        job: job,
        scheduled_at: scheduled_at,
        encryption_context: encryption_context
      }
      @payload
    end
  end

  class FakeWorkflowEnqueuer
    attr_reader :enqueue_batch_calls

    def initialize(enqueue_batch_result)
      @enqueue_batch_result = enqueue_batch_result
      @enqueue_batch_calls = []
    end

    def enqueue_batch(items, concurrency:)
      @enqueue_batch_calls << { items: items, concurrency: concurrency }
      @enqueue_batch_result
    end
  end
end

describe ActiveJob::Temporal::WorkflowEnqueuer do
  let(:client) { WorkflowEnqueuerSpecSupport::FakeClient.new }
  let(:config) { build_configuration }
  let(:logger) { Object.new }
  let(:enqueuer) { described_class.new(client, config, logger) }

  describe "#enqueue" do
    let(:job) do
      job = SimpleJob.new
      job.job_id = "test-job-id"
      job
    end

    before do
      @logger_events = call_recorded_method(ActiveJob::Temporal::Logger, :log_event)
      @logger_warnings = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      @audit_records = call_recorded_method(ActiveJob::Temporal::AuditLog, :record)
      @observability_events = call_recorded_method(ActiveJob::Temporal::Observability, :emit)
    end

    it "delegates to client.start_workflow" do
      enqueuer.enqueue(job)

      assert_equal 1, client.start_workflow_calls.size
      assert_equal ActiveJob::Temporal::WorkflowTypes::ACTIVE_JOB, client.start_workflow_calls.first[:arguments].first
    end

    it "emits enqueue observability after a workflow starts" do
      enqueuer.enqueue(job)

      assert_observability_enqueue_includes(
        job_class: "SimpleJob",
        job_id: "test-job-id",
        queue: "default",
        workflow_id: "ajwf:SimpleJob:test-job-id",
        task_queue: "default",
        duplicate: false
      )
    end

    it "records an audit event after a workflow starts" do
      enqueuer.enqueue(job)

      assert_audit_record_includes(
        workflow_id: "ajwf:SimpleJob:test-job-id",
        job_class: "SimpleJob",
        job_id: "test-job-id",
        queue: "default",
        task_queue: "default",
        duplicate: false
      )
    end

    it "returns the workflow handle when enqueue logging fails after Temporal accepts the workflow" do
      call_recorded_method(ActiveJob::Temporal::Logger, :log_event, raises: StandardError.new("logger down"))

      result = enqueuer.enqueue(job)

      assert_equal "workflow-handle", result
      assert_audit_record_includes(job_id: "test-job-id", duplicate: false)
      assert_observability_enqueue_includes(job_id: "test-job-id", duplicate: false)
      assert_logger_warning_includes(
        side_effect: "log",
        workflow_id: "ajwf:SimpleJob:test-job-id",
        job_id: "test-job-id",
        error_class: "StandardError"
      )
    end

    it "returns the workflow handle when enqueue auditing fails after Temporal accepts the workflow" do
      call_recorded_method(ActiveJob::Temporal::AuditLog, :record, raises: StandardError.new("audit down"))

      result = enqueuer.enqueue(job)

      assert_equal "workflow-handle", result
      assert_observability_enqueue_includes(job_id: "test-job-id", duplicate: false)
      assert_logger_warning_includes(
        side_effect: "audit",
        job_id: "test-job-id",
        error_class: "StandardError"
      )
    end

    it "returns the workflow handle when enqueue observability fails after Temporal accepts the workflow" do
      call_recorded_method(ActiveJob::Temporal::Observability, :emit) do |event_name, *_arguments|
        raise StandardError, "metrics down" if event_name == :enqueue
      end

      result = enqueuer.enqueue(job)

      assert_equal "workflow-handle", result
      assert_logger_warning_includes(
        side_effect: "observability",
        job_id: "test-job-id",
        error_class: "StandardError"
      )
    end

    it "returns the workflow handle" do
      handle = "test-workflow-handle"
      client.start_workflow_results = [handle]

      result = enqueuer.enqueue(job)

      assert_equal handle, result
    end

    it "includes the workflow ID in options" do
      client.on_start_workflow do |_workflow_class, _payload, **options|
        assert_equal "ajwf:SimpleJob:test-job-id", options[:id]
        "handle"
      end

      enqueuer.enqueue(job)
    end

    it "uses the injected workflow ID builder" do
      workflow_id_builder = WorkflowEnqueuerSpecSupport::FakeWorkflowIdBuilder.new("custom-workflow-id")
      enqueuer = described_class.new(client, config, logger, workflow_id_builder: workflow_id_builder)

      client.on_start_workflow do |_workflow_class, _payload, **options|
        assert_equal "custom-workflow-id", options[:id]
        "handle"
      end

      enqueuer.enqueue(job)

      assert_equal [job], workflow_id_builder.build_calls
    end

    it "builds encrypted payloads with the target workflow context" do
      payload = { job_class: "SimpleJob", job_id: job.job_id, queue_name: "default" }
      payload_builder = WorkflowEnqueuerSpecSupport::FakePayloadBuilder.new(payload)
      enqueuer = described_class.new(client, config, logger, payload_builder: payload_builder)

      enqueuer.enqueue(job)

      assert_equal(
        [
          {
            job: job,
            scheduled_at: nil,
            encryption_context: { namespace: "default", workflow_id: "ajwf:SimpleJob:test-job-id" }
          }
        ],
        payload_builder.build_calls
      )
    end

    it "rejects blank dead letter queues before starting a workflow" do
      payload = {
        job_class: "SimpleJob",
        job_id: job.job_id,
        queue_name: "default",
        dead_letter: { queue: " " }
      }
      payload_builder = WorkflowEnqueuerSpecSupport::FakePayloadBuilder.new(payload)
      enqueuer = described_class.new(client, config, logger, payload_builder: payload_builder)

      error = assert_raises(ActiveJob::Temporal::ConfigurationError) { enqueuer.enqueue(job) }

      assert_match(/dead_letter\.queue cannot be blank/, error.message)
      assert_empty client.start_workflow_calls
    end

    it "rejects blank chain dead letter queues before starting a workflow" do
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
      payload_builder = WorkflowEnqueuerSpecSupport::FakePayloadBuilder.new(payload)
      enqueuer = described_class.new(client, config, logger, payload_builder: payload_builder)

      error = assert_raises(ActiveJob::Temporal::ConfigurationError) { enqueuer.enqueue(job) }

      assert_match(/chain\.dead_letter\.queue cannot be blank/, error.message)
      assert_empty client.start_workflow_calls
    end

    it "uses the configured workflow ID generator" do
      config.workflow_id_generator = ->(job) { "custom:#{job.class.name}:#{job.job_id}" }
      enqueuer = described_class.new(client, config, logger)

      client.on_start_workflow do |_workflow_class, _payload, **options|
        assert_equal "custom:SimpleJob:test-job-id", options[:id]
        "handle"
      end

      enqueuer.enqueue(job)
    end

    it "rejects invalid configured workflow IDs before starting a workflow" do
      config.workflow_id_generator = ->(_job) { "invalid\nworkflow" }
      enqueuer = described_class.new(client, config, logger)

      error = assert_raises(ActiveJob::Temporal::ConfigurationError) { enqueuer.enqueue(job) }

      assert_match(/invalid workflow ID/, error.message)
      assert_empty client.start_workflow_calls
    end

    it "includes FAIL conflict policy" do
      client.on_start_workflow do |_workflow_class, _payload, **options|
        assert_equal Temporalio::WorkflowIDConflictPolicy::FAIL, options[:id_conflict_policy]
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

      client.on_start_workflow do |_workflow_class, _payload, **options|
        assert_equal "high_priority", options[:task_queue]
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

      client.on_start_workflow do |_workflow_class, _payload, **options|
        assert_equal "high_priority", options[:task_queue]
        "handle"
      end

      enqueuer.enqueue(priority_job)

      assert_observability_enqueue_includes(
        job_class: "PriorityMetricJob",
        job_id: "priority-metric-job-id",
        queue: "default",
        task_queue: "high_priority",
        duplicate: false
      )
    end

    it "includes global activity timeout defaults in the payload" do
      config.default_heartbeat_timeout = 45.seconds
      config.default_schedule_to_start_timeout = 2.minutes
      config.default_schedule_to_close_timeout = 20.minutes

      client.on_start_workflow do |_workflow_class, payload, **_options|
        assert_equal(
          {
            start_to_close_timeout: 900.0,
            schedule_to_close_timeout: 1200.0,
            schedule_to_start_timeout: 120.0,
            heartbeat_timeout: 45.0
          },
          payload[:default_activity_options]
        )
        "handle"
      end

      enqueuer.enqueue(job)
    end

    it "includes job tags in search attributes" do
      job.define_singleton_method(:temporal_tags) { %w[urgent customer_123] }
      aj_tags_key = Temporalio::SearchAttributes::Key.new(
        "ajTags",
        Temporalio::SearchAttributes::IndexedValueType::KEYWORD_LIST
      )

      client.on_start_workflow do |_workflow_class, _payload, **options|
        assert_equal %w[urgent customer_123], options[:search_attributes][aj_tags_key]
        "handle"
      end

      enqueuer.enqueue(job)
    end

    it "raises a duplicate enqueue error for duplicate workflows" do
      error_class = Class.new(StandardError)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", error_class)
      client.start_workflow_error = error_class.new("already started")

      error = assert_raises(ActiveJob::Temporal::DuplicateEnqueueError) { enqueuer.enqueue(job) }

      assert_match(/already enqueued/, error.message)
      assert_observability_enqueue_includes(
        job_class: "SimpleJob",
        job_id: "test-job-id",
        duplicate: true
      )
      assert_audit_record_includes(job_id: "test-job-id", duplicate: true)
    end

    it "raises a duplicate enqueue error for duplicate workflows when enqueue logging fails" do
      error_class = Class.new(StandardError)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", error_class)
      client.start_workflow_error = error_class.new("already started")
      call_recorded_method(ActiveJob::Temporal::Logger, :log_event, raises: StandardError.new("logger down"))

      error = assert_raises(ActiveJob::Temporal::DuplicateEnqueueError) { enqueuer.enqueue(job) }

      assert_match(/already enqueued/, error.message)
      assert_audit_record_includes(job_id: "test-job-id", duplicate: true)
      assert_logger_warning_includes(
        side_effect: "log",
        job_id: "test-job-id",
        duplicate: true
      )
    end

    it "raises a duplicate enqueue error for current SDK duplicate workflow errors" do
      client.start_workflow_error = Temporalio::Error::WorkflowAlreadyStartedError.new(
        workflow_id: "ajwf:SimpleJob:test-job-id",
        workflow_type: "ActiveJob::Temporal::Workflows::AjWorkflow",
        run_id: "test-run-id"
      )

      error = assert_raises(ActiveJob::Temporal::DuplicateEnqueueError) { enqueuer.enqueue(job) }

      assert_match(/already enqueued/, error.message)
      assert_observability_enqueue_includes(job_class: "SimpleJob", job_id: "test-job-id", duplicate: true)
    end

    it "raises a duplicate enqueue error for already-exists RPC duplicate workflow errors" do
      error_class = Class.new(StandardError) do
        attr_reader :code

        def initialize
          @code = Temporalio::Error::RPCError::Code::ALREADY_EXISTS
          super("Workflow execution already started")
        end
      end
      client.start_workflow_error = error_class.new

      error = assert_raises(ActiveJob::Temporal::DuplicateEnqueueError) { enqueuer.enqueue(job) }

      assert_match(/already enqueued/, error.message)
      assert_observability_enqueue_includes(job_class: "SimpleJob", job_id: "test-job-id", duplicate: true)
    end

    it "raises ActiveJob::EnqueueError for non-duplicate errors" do
      original_error = StandardError.new("Connection failed")
      client.start_workflow_error = original_error

      error = assert_raises(ActiveJob::EnqueueError) { enqueuer.enqueue(job) }

      assert_same original_error, error.cause
    end

    describe "with scheduled_at" do
      it "accepts scheduled_at parameter" do
        scheduled_time = 1.hour.from_now

        client.on_start_workflow do |_workflow_class, payload, **_options|
          assert_equal scheduled_time.iso8601, payload[:scheduled_at]
          "handle"
        end

        enqueuer.enqueue(job, scheduled_at: scheduled_time)
      end

      it "treats scheduled_at equal to now as immediate" do
        now = Time.utc(2026, 5, 25, 12, 0, 0)
        call_recorded_method(Time, :now, returns: now)
        client.on_start_workflow do |_workflow_class, payload, **_options|
          assert_nil payload[:scheduled_at]
          "handle"
        end

        assert_equal "handle", enqueuer.enqueue(job, scheduled_at: now)
      end

      it "treats slightly past scheduled_at values as immediate" do
        now = Time.utc(2026, 5, 25, 12, 0, 0)
        call_recorded_method(Time, :now, returns: now)
        client.on_start_workflow do |_workflow_class, payload, **_options|
          assert_nil payload[:scheduled_at]
          "handle"
        end

        assert_equal "handle", enqueuer.enqueue(job, scheduled_at: now - 0.1)
      end

      it "rejects malformed scheduled_at values before starting a workflow" do
        error = assert_raises(ArgumentError) { enqueuer.enqueue(job, scheduled_at: "not-a-date") }

        assert_match(/scheduled_at must be/, error.message)
        assert_empty client.start_workflow_calls
      end
    end

    describe "with blank queue name" do
      it "raises ConfigurationError" do
        job.queue_name = nil

        error = assert_raises(ActiveJob::Temporal::ConfigurationError) { enqueuer.enqueue(job) }

        assert_match(/queue name cannot be blank/, error.message)
      end
    end

    describe "with temporal_options" do
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
        client.on_start_workflow do |_workflow_class, payload, **_options|
          assert_hash_includes({ start_to_close_timeout: 900.0 }, payload[:default_activity_options])
          refute_nil payload[:temporal_options]
          assert_equal 7200.0, payload[:temporal_options][:start_to_close_timeout]
          assert_equal 30.0, payload[:temporal_options][:heartbeat_timeout]
          "handle"
        end

        enqueuer.enqueue(timeout_job)
      end

      it "omits temporal_options from payload when not defined" do
        client.on_start_workflow do |_workflow_class, payload, **_options|
          assert_nil payload[:temporal_options]
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
      @logger_events = call_recorded_method(ActiveJob::Temporal::Logger, :log_event)
      @logger_warnings = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      @audit_records = call_recorded_method(ActiveJob::Temporal::AuditLog, :record)
      @observability_events = call_recorded_method(ActiveJob::Temporal::Observability, :emit)
    end

    it "enqueues multiple jobs and returns per-job success results" do
      client.start_workflow_results = %w[first-handle second-handle]

      result = enqueuer.enqueue_batch([first_job, second_job])

      assert result.success?
      assert_equal 2, result.success_count
      assert_equal 0, result.duplicate_count
      assert_equal 0, result.failure_count
      assert_unordered_equal(
        [
          {
            index: 0,
            job_class: "SimpleJob",
            job_id: "batch-job-1",
            status: :success,
            handle: "first-handle"
          },
          {
            index: 1,
            job_class: "ScheduledJob",
            job_id: "batch-job-2",
            status: :success,
            handle: "second-handle"
          }
        ],
        result.results.map(&:to_h)
      )
    end

    it "preserves per-job scheduled times and task queue routing" do
      scheduled_time = 1.hour.from_now
      entries = [
        first_job,
        { job: second_job, scheduled_at: scheduled_time }
      ]

      enqueuer.enqueue_batch(entries)

      first_call = client.start_workflow_calls[0]
      second_call = client.start_workflow_calls[1]
      assert_equal "mailers", first_call[:keywords][:task_queue]
      assert_nil first_call[:arguments][1][:scheduled_at]
      assert_equal "reports", second_call[:keywords][:task_queue]
      assert_equal scheduled_time.iso8601, second_call[:arguments][1][:scheduled_at]
    end

    it "treats due batch scheduled times as immediate" do
      now = Time.utc(2026, 5, 25, 12, 0, 0)
      call_recorded_method(Time, :now, returns: now)

      enqueuer.enqueue_batch([
                               { job: first_job, scheduled_at: now },
                               { job: second_job, scheduled_at: now - 1 }
                             ])

      scheduled_values = client.start_workflow_calls.map { |call| call[:arguments][1][:scheduled_at] }
      assert_equal [nil, nil], scheduled_values
    end

    it "reports duplicate jobs per item" do
      error_class = Class.new(StandardError)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", error_class)
      call_count = 0

      client.on_start_workflow do
        call_count += 1
        raise error_class, "already started" if call_count == 2

        "first-handle"
      end

      result = enqueuer.enqueue_batch([first_job, second_job])

      assert_equal 1, result.success_count
      assert_equal 1, result.duplicate_count
      assert_equal 0, result.failure_count
      assert_equal :duplicate, result.results[1].status
      assert_nil result.results[1].handle
    end

    it "reports enqueue failures per item without stopping the batch" do
      call_count = 0

      client.on_start_workflow do
        call_count += 1
        raise StandardError, "connection failed" if call_count == 2

        "first-handle"
      end

      result = enqueuer.enqueue_batch([first_job, second_job])

      refute result.success?
      assert_equal 1, result.success_count
      assert_equal 1, result.failure_count
      assert_equal 1, result.failures.first.index
      assert_kind_of ActiveJob::EnqueueError, result.failures.first.error
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

      error = assert_raises(ActiveJob::Temporal::BatchEnqueueValidationError) do
        enqueuer.enqueue_batch(entries)
      end

      error_indexes = error.errors.map { |entry| entry[:index] }
      assert_equal [1, 2, 3], error_indexes
      assert_includes error.message, "scheduled_at must be"
      assert_includes error.message, "queue name cannot be blank"
      assert_includes error.message, "ActiveJob instance"
      assert_empty client.start_workflow_calls
    end

    it "rejects invalid concurrency limits" do
      error = assert_raises(ArgumentError) { enqueuer.enqueue_batch([first_job], concurrency: 0) }

      assert_match(/concurrency must be a positive integer/, error.message)
      assert_empty client.start_workflow_calls
    end

    it "enqueues all jobs when concurrency is greater than one" do
      result = enqueuer.enqueue_batch([first_job, second_job], concurrency: 2)

      assert_equal 2, result.success_count
      assert_equal 2, client.start_workflow_calls.size
    end
  end

  describe "initialization" do
    it "accepts optional logger" do
      custom_logger = Object.new
      enqueuer_with_logger = described_class.new(client, config, custom_logger)

      assert_kind_of described_class, enqueuer_with_logger
    end

    it "uses config logger when not provided" do
      enqueuer_without_logger = described_class.new(client, config)

      assert_kind_of described_class, enqueuer_without_logger
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

  def assert_observability_enqueue_includes(expected_attributes)
    assert_recorded_hash_argument(
      @observability_events,
      :emit,
      :enqueue,
      argument_position: 1,
      expected_attributes: expected_attributes
    )
  end

  def assert_audit_record_includes(expected_attributes)
    assert_recorded_hash_argument(
      @audit_records,
      :record,
      "job.enqueued",
      argument_position: 1,
      expected_attributes: expected_attributes
    )
  end

  def assert_logger_warning_includes(expected_attributes)
    assert_recorded_hash_argument(
      @logger_warnings,
      :warn,
      "workflow_enqueue_side_effect_failed",
      argument_position: 1,
      expected_attributes: expected_attributes
    )
  end

  def assert_recorded_hash_argument(
    call_recorder,
    method_name,
    *leading_arguments,
    argument_position:,
    expected_attributes:
  )
    call = first_recorded_call(call_recorder, method_name, *leading_arguments)

    assert_hash_includes expected_attributes, call.arguments.fetch(argument_position)
  end

  def first_recorded_call(call_recorder, method_name, *leading_arguments)
    calls = call_recorder.calls_for(method_name).select do |call|
      call.arguments.take(leading_arguments.length) == leading_arguments
    end
    assert calls.any?, "Expected #{method_name} to be called with leading arguments #{leading_arguments.inspect}"

    calls.first
  end
end

describe ActiveJob::Temporal do
  describe ".enqueue_batch" do
    it "delegates to a workflow enqueuer with the current client and configuration" do
      configuration = ActiveJob::Temporal::Configuration.new
      configuration.target = "localhost:7233"
      configuration.namespace = "default"
      items = [SimpleJob.new]
      result = ActiveJob::Temporal::BatchEnqueueResult.new([])
      enqueuer = WorkflowEnqueuerSpecSupport::FakeWorkflowEnqueuer.new(result)

      client_calls = call_recorded_method(described_class, :client, returns: "client")
      config_calls = call_recorded_method(described_class, :config, returns: configuration)
      workflow_enqueuer_calls = call_recorded_method(
        ActiveJob::Temporal::WorkflowEnqueuer,
        :new,
        returns: enqueuer
      )

      assert_same result, described_class.enqueue_batch(items, concurrency: 3)

      workflow_enqueuer_call = workflow_enqueuer_calls.calls_for(:new).first
      assert_instance_of Proc, workflow_enqueuer_call.arguments[0]
      assert_equal configuration, workflow_enqueuer_call.arguments[1]
      assert_equal configuration.logger, workflow_enqueuer_call.arguments[2]
      assert_equal "client", workflow_enqueuer_call.arguments[0].call
      assert_equal 1, client_calls.calls_for(:client).size
      assert_equal 2, config_calls.calls_for(:config).size
      assert_equal [{ items: items, concurrency: 3 }], enqueuer.enqueue_batch_calls
    end
  end
end
