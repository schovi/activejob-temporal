# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/activities/aj_runner_activity"
require "stringio"
require_relative "../fixtures/sample_jobs"

module StandaloneActivitySpecSupport
  ActivityInfo = Struct.new(:workflow_id, :workflow_namespace, :activity_id, :namespace, :activity_run_id, :attempt)
  ActivityDescription = Struct.new(:activity_id, :activity_run_id, :status, :last_started_time, :close_time,
                                   :attempt, :last_failure, keyword_init: true)
  WorkflowDescription = Struct.new(:id, :run_id, :status, :start_time, :close_time, keyword_init: true)
  Context = Struct.new(:info)
end

describe "Standalone activity enqueue" do
  let(:job_class) { stub_const("StandaloneUnitJob", Class.new(TestJob) { temporal_standalone_activity }) }
  let(:job) { job_class.new }
  let(:config) { ActiveJob::Temporal::Configuration.new }
  let(:client) { Object.new }
  let(:enqueuer) { ActiveJob::Temporal::WorkflowEnqueuer.new(client, config) }

  it "inherits the flag and lets a subclass opt out without changing timeout options" do
    child_class = Class.new(job_class)

    refute TestJob.temporal_standalone_activity?
    assert job_class.temporal_standalone_activity?
    assert child_class.temporal_standalone_activity?
    child_class.temporal_standalone_activity false
    refute child_class.temporal_standalone_activity?
    assert job_class.temporal_standalone_activity?
    assert_empty job_class.temporal_options
  end

  it "starts the runner with the resolved queue, timeouts, priority, search attributes, and delay" do
    calls = call_recorded_method(client, :start_activity, returns: :activity_handle)
    events = call_recorded_method(ActiveJob::Temporal::Observability, :emit)
    audit = call_recorded_method(ActiveJob::Temporal::AuditLog, :record)
    config.task_queue_prefix = "unit-"
    priority = Temporalio::Priority.new(priority_key: 2)
    config.priority_resolver = ->(_job) { priority }
    job_class.temporal_options(start_to_close_timeout: 30.seconds)
    now = Time.now
    call_recorded_method(Time, :now, returns: now)

    assert_equal :activity_handle, enqueuer.enqueue(job, scheduled_at: now + 60)
    call = calls.calls_for(:start_activity).sole
    assert_equal ActiveJob::Temporal::Activities::AjRunnerActivity, call.arguments.first
    assert_equal job.job_id, call.arguments.last.fetch(:job_id)
    id = ActiveJob::Temporal::Adapter.build_workflow_id(job)
    assert_hash_includes(
      { id: id, task_queue: "unit-default", start_delay: 60.0, start_to_close_timeout: 30.0, priority: priority,
        id_conflict_policy: Temporalio::ActivityIDConflictPolicy::FAIL },
      call.keywords
    )
    key = Temporalio::SearchAttributes::Key.new("ajJobId", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)
    assert_equal job.job_id, call.keywords.fetch(:search_attributes)[key]
    enqueue_event = events.calls_for(:emit).find { |event| event.arguments.first == :enqueue }
    assert_equal true, enqueue_event.arguments.last[:standalone]
    assert_equal true, audit.calls_for(:record).sole.arguments.last[:standalone]
  end

  it "enqueues mixed modes in the same batch" do
    activities = call_recorded_method(client, :start_activity, returns: :activity)
    workflows = call_recorded_method(client, :start_workflow, returns: :workflow)

    result = enqueuer.enqueue_batch([job, TestJob.new])

    assert_equal 2, result.success_count
    assert_equal 1, activities.calls_for(:start_activity).size
    assert_equal 1, workflows.calls_for(:start_workflow).size
  end

  it "builds a recurring schedule with a workflow action for an opted-in class" do
    job_class.rate_limit(1, per: 1.second)
    config.rate_limiter = ActiveJob::Temporal::RateLimiters::Memory.new
    schedule = ActiveJob::Temporal::Schedule.new(job_class, cron: "0 2 * * *", config: config)

    action = schedule.to_temporal_schedule.action

    assert_instance_of Temporalio::Client::Schedule::Action::StartWorkflow, action
    assert action.args.first.key?(:rate_limits)
  end

  it "maps activity duplicates to DuplicateEnqueueError" do
    error = Temporalio::Error::ActivityAlreadyStartedError.new(
      activity_id: job.job_id, activity_type: "AjRunnerActivity", activity_run_id: "run"
    )
    call_recorded_method(client, :start_activity, raises: error)

    assert_raises(ActiveJob::Temporal::DuplicateEnqueueError) { enqueuer.enqueue(job) }
  end

  it "rejects a client that does not support standalone activities" do
    error = assert_raises(ActiveJob::Temporal::ConfigurationError) { enqueuer.enqueue(job) }

    assert_equal "standalone activities require temporalio >= 1.5", error.message
  end

  {
    rate_limits: ->(job) { job.class.rate_limit(1, per: 1.second) },
    chain: ->(job) { job.set(chain: [TestJob]) },
    child_workflows: ->(job) { job.set(child_workflows: [TestJob]) },
    dependencies: ->(job) { job.set(depends_on: [TestJob.new]) },
    workflow_interactions: ->(job) { job.class.temporal_signal(:refresh) },
    workflow_identity: ->(job) { job.class.temporal_workflow_name("CustomWorkflow") },
    workflow_id_prefix: ->(job) { job.class.temporal_workflow_id_prefix("custom") }
  }.each do |feature, configure|
    it "rejects #{feature} before encrypting the payload" do
      configure.call(job)
      starts = call_recorded_method(client, :start_activity)
      encrypt = call_recorded_method(ActiveJob::Temporal::Payload, :encrypt_payload)

      error = assert_raises(ActiveJob::Temporal::ConfigurationError) { enqueuer.enqueue(job) }

      assert_match(feature == :workflow_id_prefix ? "workflow_identity" : feature.to_s, error.message)
      refute_called encrypt, :encrypt_payload
      refute_called starts, :start_activity
    end
  end

  it "skips the DLQ, ignores its attempt limit, and warns once across enqueuers" do
    config.dead_letter_queue = "dead-jobs"
    config.dead_letter_after_attempts = 1
    config.default_retry_max_attempts = 4
    output = StringIO.new
    config.logger = Logger.new(output)
    starts = call_recorded_method(client, :start_activity)

    enqueuer.enqueue(job)
    ActiveJob::Temporal::WorkflowEnqueuer.new(client, config).enqueue(job_class.new)

    assert_equal 1, output.string.lines.grep(/standalone_activity_dlq_skipped/).size
    starts.calls_for(:start_activity).each do |call|
      refute call.arguments.last.key?(:dead_letter)
      assert_equal 4, call.keywords.fetch(:retry_policy).max_attempts
    end
  end

  it "uses the 900 second timeout fallback before applying job options" do
    config.default_activity_timeout = nil
    job_class.temporal_options(heartbeat_timeout: 5.seconds)
    builder = ActiveJob::Temporal::JobPayloadBuilder.new(config)

    assert_hash_includes(
      { start_to_close_timeout: 900.0, heartbeat_timeout: 5.0 },
      builder.standalone_activity_options(job)
    )
  end

  it "serializes the same retry policy as the original workflow mapper" do
    hash = { "initial_interval" => 2.0, backoff_coefficient: 1.5, "maximum_attempts" => 0,
             max_attempts: 9, "max_interval" => 20.0, non_retryable_error_types: ["ArgumentError"] }
    original_policy = Temporalio::RetryPolicy.new(
      initial_interval: 2.0, backoff_coefficient: 1.5, max_attempts: 0, max_interval: 20.0,
      non_retryable_error_types: ["ArgumentError"]
    )

    mapped_policy = ActiveJob::Temporal::RetryMapper.temporal_policy(hash)
    assert_equal original_policy._to_proto.to_proto, mapped_policy._to_proto.to_proto
  end

  it "rejects pause signals and other workflow interactions at call time" do
    %i[signal query update].each do |operation|
      error = assert_raises(ActiveJob::Temporal::ConfigurationError) do
        ActiveJob::Temporal::SignalQuery.public_send(operation, job_class, job.job_id, "pause")
      end
      assert_match(/standalone activities do not support/, error.message)
    end
  end
end

describe "Standalone activity lookup" do
  let(:job_class) { stub_const("StandaloneLookupJob", Class.new(TestJob)) }
  let(:job_id) { "lookup-id" }
  let(:id) { ActiveJob::Temporal::WorkflowIdBuilder.default_from_job_class(job_class, job_id) }
  let(:client) { Object.new }
  let(:activity) { Struct.new(:id).new(id) }
  let(:workflow) { Object.new }
  let(:not_found) do
    Temporalio::Error::RPCError.new("missing", code: Temporalio::Error::RPCError::Code::NOT_FOUND, raw_grpc_status: nil)
  end

  before do
    call_recorded_method(ActiveJob::Temporal, :client, returns: client)
    call_recorded_method(client, :activity_handle, returns: activity)
    call_recorded_method(client, :workflow_handle, returns: workflow)
  end

  it "looks up an opted-in activity directly for status and cancellation" do
    job_class.temporal_standalone_activity
    describe_running_activity
    requests = call_recorded_method(activity, :cancel)

    assert_equal :running, ActiveJob::Temporal::Inspect.status(job_class, job_id)[:state]
    assert_nil ActiveJob::Temporal.cancel(job_class, job_id)
    assert_equal 1, requests.calls_for(:cancel).size
  end

  it "falls back from a missing activity to the workflow" do
    job_class.temporal_standalone_activity
    call_recorded_method(activity, :describe, raises: not_found)
    status = Temporalio::Client::WorkflowExecutionStatus::RUNNING
    description = StandaloneActivitySpecSupport::WorkflowDescription.new(id: id, status: status)
    call_recorded_method(workflow, :describe, returns: description)
    call_recorded_method(client, :list_workflows, returns: [description])
    requests = call_recorded_method(workflow, :cancel)

    assert_equal :running, ActiveJob::Temporal::Inspect.status(job_class, job_id)[:state]
    assert_nil ActiveJob::Temporal.cancel(job_class, job_id)
    assert_equal 1, requests.calls_for(:cancel).size
  end

  it "falls back from a missing workflow to the activity" do
    call_recorded_method(workflow, :describe, raises: not_found)
    call_recorded_method(client, :list_workflows, returns: [])
    describe_running_activity
    requests = call_recorded_method(activity, :cancel)

    assert_equal :running, ActiveJob::Temporal::Inspect.status(job_class, job_id)[:state]
    assert_nil ActiveJob::Temporal.cancel(job_class, job_id)
    assert_equal 1, requests.calls_for(:cancel).size
  end

  def describe_running_activity
    status = Temporalio::Client::ActivityExecutionStatus::RUNNING
    description = StandaloneActivitySpecSupport::ActivityDescription.new(activity_id: id, status: status, attempt: 1)
    call_recorded_method(activity, :describe, returns: description)
  end
end

describe "Standalone runner context" do
  it "uses activity context for encryption, idempotency, and audit attributes" do
    job_class = stub_const("StandaloneContextJob", Class.new(TestJob) do
      def perform = Fiber[:aj_temporal_idempotency_key]
    end)
    payload = ActiveJob::Temporal::Payload.from_job(job_class.new, encrypt: false, offload: false)
    payload[:schedule_workflow_id_prefix] = "activity"
    info = StandaloneActivitySpecSupport::ActivityInfo.new(nil, nil, "activity-id", "worker-namespace", "run", 2)
    context = StandaloneActivitySpecSupport::Context.new(info)
    call_recorded_method(Temporalio::Activity::Context, :exist?, returns: true)
    call_recorded_method(Temporalio::Activity::Context, :current, returns: context)
    deserialization = call_recorded_method(ActiveJob::Temporal::Payload, :deserialize_payload, returns: payload)

    assert_equal "activity-id/runner", ActiveJob::Temporal::Activities::AjRunnerActivity.new.execute(payload)
    assert_called_with deserialization, :deserialize_payload, payload,
                       encryption_context: { namespace: "worker-namespace", workflow_id: "activity-id" }
    assert_hash_includes(
      { workflow_id: "activity-id", run_id: "run", attempt: 2 },
      ActiveJob::Temporal::AuditLog.activity_attributes_from_payload(payload)
    )
    assert_hash_includes(
      { workflow_id: "activity-id", namespace: "worker-namespace" },
      ActiveJob::Temporal::Observability.attributes_from_payload(payload)
    )
  end
end
