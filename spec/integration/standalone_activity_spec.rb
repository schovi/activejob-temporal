# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/worker_runtime"
require "securerandom"
require "timeout"

module StandaloneActivityIntegration
  class Job < ActiveJob::Base
    temporal_standalone_activity

    def perform(value)
      [value, Fiber[:aj_temporal_idempotency_key]]
    end
  end

  class RetryingJob < Job
    retry_on RuntimeError, wait: 0.1.seconds, attempts: 3

    def perform
      attempt = Temporalio::Activity::Context.current.info.attempt
      raise "retry once" if attempt == 1

      attempt
    end
  end

  class DiscardingJob < Job
    discard_on ArgumentError

    def perform
      raise ArgumentError, "discard this"
    end
  end
end

describe "Standalone ActiveJob activities", :integration do
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal
    @task_queue = "standalone-#{SecureRandom.hex(4)}"
    @handles = []
    example.run
  ensure
    @handles.each { |handle| clean_up_activity(handle) }
    stop_temporal_worker(@worker_thread)
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "runs on an activity worker and exposes the result, state, and search attributes" do
    start_worker
    job, handle = enqueue(StandaloneActivityIntegration::Job, 42)

    assert_equal [42, "#{handle.id}/runner"], result(handle)
    status = ActiveJob::Temporal::Inspect.status(job.class, job.job_id)
    assert_equal :completed, status[:state]
    assert_equal handle.id, status[:workflow_id]
    assert_instance_of Time, status[:closed_at]
    key = Temporalio::SearchAttributes::Key.new("ajJobId", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)
    assert_equal job.job_id, handle.describe.search_attributes[key]
  end

  it "retries a transient error" do
    start_worker
    _, handle = enqueue(StandaloneActivityIntegration::RetryingJob)

    assert_equal 2, result(handle)
  end

  it "discards an error without retrying it" do
    start_worker
    _, handle = enqueue(StandaloneActivityIntegration::DiscardingJob)

    error = assert_raises(Temporalio::Error::ActivityFailedError) { result(handle) }
    assert_equal "ArgumentError", error.cause.type
    assert_equal 1, handle.describe.attempt
  end

  it "waits before dispatching the activity" do
    start_worker
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _, handle = enqueue(StandaloneActivityIntegration::Job, 42, wait: 1.second)

    assert_equal 42, result(handle).first
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at, :>=, 0.9
  end

  it "rejects a duplicate job ID while its activity is open" do
    job, = enqueue(StandaloneActivityIntegration::Job, 42, wait: 30.seconds)

    assert_raises(ActiveJob::Temporal::DuplicateEnqueueError) { enqueuer.enqueue(job) }
  end

  it "cancels a delayed activity and returns false once it closes" do
    job, handle = enqueue(StandaloneActivityIntegration::Job, 42, wait: 30.seconds)

    assert_equal :running, ActiveJob::Temporal::Inspect.status(job.class, job.job_id)[:state]
    assert_nil ActiveJob::Temporal.cancel(job.class, job.job_id)
    error = assert_raises(Temporalio::Error::ActivityFailedError) { result(handle) }
    assert_instance_of Temporalio::Error::CanceledError, error.cause
    assert_equal :canceled, ActiveJob::Temporal::Inspect.status(job.class, job.job_id)[:state]
    assert_equal false, ActiveJob::Temporal.cancel(job.class, job.job_id)
  end

  it "decrypts the payload with the trusted activity ID and namespace" do
    config = ActiveJob::Temporal.config
    original_encryption = config.encrypt_payload
    original_key = config.encryption_key
    config.encrypt_payload = true
    config.encryption_key = Base64.strict_encode64(SecureRandom.random_bytes(32))
    start_worker

    _, handle = enqueue(StandaloneActivityIntegration::Job, "encrypted")

    assert_equal ["encrypted", "#{handle.id}/runner"], result(handle)
  ensure
    config.encrypt_payload = original_encryption
    config.encryption_key = original_key
  end

  private

  def start_worker
    skip "SDK has no standalone activity support" unless client.respond_to?(:start_activity)

    @worker_thread = start_temporal_worker(@task_queue, workflows: [])
  end

  def enqueue(job_class, *, **)
    skip "SDK has no standalone activity support" unless client.respond_to?(:start_activity)

    job = job_class.set(queue: @task_queue, **).perform_later(*) do |attempted|
      raise attempted.enqueue_error if attempted.enqueue_error
    end
    assert job, "ActiveJob did not enqueue the activity"
    handle = client.activity_handle(ActiveJob::Temporal::Adapter.build_workflow_id(job))
    @handles << handle
    [job, handle]
  rescue ActiveJob::EnqueueError => e
    raise unless e.cause.is_a?(Temporalio::Error::RPCError)
    raise unless e.cause.code == Temporalio::Error::RPCError::Code::UNIMPLEMENTED

    skip "Server has no standalone activity support"
  end

  def client
    TemporalTestHelper.client
  end

  def enqueuer
    ActiveJob::Temporal::WorkflowEnqueuer.new(client, ActiveJob::Temporal.config)
  end

  def result(handle)
    Timeout.timeout(10) { handle.result }
  end

  def clean_up_activity(handle)
    handle.terminate if ActiveJob::Temporal::StandaloneActivity.state(handle.describe.status) == :running
  rescue Temporalio::Error::RPCError
    nil
  end
end
