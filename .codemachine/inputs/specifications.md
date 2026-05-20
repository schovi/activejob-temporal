Below is a precise, implementation-ready SPEC for the first release of the activejob-temporal gem. It’s written for senior engineers and AI coding agents. It defines scope, APIs, internal architecture, and measurable acceptance criteria. No fluff.

⸻

activejob-temporal — v0.1 SPEC

0. Scope (v0.1)
	•	One Temporal Workflow: AjWorkflow
	•	One Temporal Activity: AjRunnerActivity
	•	One Rails adapter: ActiveJob::QueueAdapters::TemporalAdapter
	•	Supports:
	•	enqueue and enqueue_at (scheduled execution)
	•	Basic retries (map from retry_on/discard_on)
	•	Idempotency / de-duplication
	•	Cancellation
	•	Visibility via Search Attributes
	•	Non-goals (v0.1): Update handlers, child workflows, multi-activity orchestration, Schedules API, DLQ orchestration UI.

⸻

1. Supported Platforms & Dependencies
	•	Ruby >= 4.0
	•	Rails >= 7.2 (ActiveJob)
	•	temporalio >= 1.4.1 [gem 'temporalio']
	•	Optional: opentelemetry-sdk for tracing; semantic_logger or logger

⸻

2. Public Surface

2.1 Adapter Registration

# config/initializers/active_job.rb
Rails.application.config.active_job.queue_adapter = :temporal

2.2 What Stays the Same for App Code

Developers write standard ActiveJob jobs:

class SendInvoiceJob < ApplicationJob
  queue_as :billing
  retry_on PSP::TransientError, wait: 30.seconds, attempts: 5
  discard_on PSP::FatalError

  def perform(invoice_id)
    InvoiceSender.call(invoice_id)
  end
end

SendInvoiceJob.set(wait: 5.minutes).perform_later(42)

No changes to the job interface.

2.3 Optional Helper (Cancellation)

ActiveJob::Temporal.cancel(job_id)  # best-effort cancel via workflow handle


⸻

3. Behavioral Contract

3.1 Enqueue
	•	enqueue(job):
	•	Establish Temporal client (memoized).
	•	Start AjWorkflow with:
	•	workflow_id = "ajwf:#{job.class.name}:#{job.job_id}" (deterministic)
	•	task_queue = resolve_task_queue(job) (defaults to job.queue_name || "default")
	•	id_conflict_policy = :reject (dedupe)
	•	search_attributes (see §6.3)
	•	Input: serialized AJ arguments (ActiveJob::Arguments).

3.2 Enqueue At (Scheduling)
	•	enqueue_at(job, timestamp):
	•	Same as enqueue, but pass scheduled_at to workflow.
	•	In AjWorkflow.execute:
	•	If scheduled_at > Workflow.now, call Workflow.sleep(scheduled_at - now).
	•	This is durable and non-blocking.

3.3 Execution Model
	•	AjWorkflow executes exactly one activity: AjRunnerActivity.
	•	AjRunnerActivity:
	•	Deserializes AJ args.
	•	Instantiates the job class and calls perform(*args).
	•	Maps errors to Temporal semantics (see §4).

3.4 Retries
	•	Default: retries are applied at the Activity level.
	•	Map from AJ DSL:
	•	retry_on E, wait:, attempts: → Activity RetryPolicy:
	•	initial_interval = wait (fallback to 30s)
	•	backoff_coefficient = 2.0
	•	maximum_attempts = attempts (fallback to 1)
	•	discard_on E → raise ApplicationError(non_retryable: true) when such exception is caught.
	•	If multiple retry_on are declared, pick the first matching exception by ancestry order.
	•	Workflow itself does not retry in v0.1.

3.5 Idempotency
	•	workflow_id as above + id_conflict_policy: :reject prevents duplicate starts for the same job_id.
	•	Activity calls must be idempotent at the app layer. Provide an idempotency key in activity context:
	•	idempotency_key = "#{workflow_id}/runner" (exposed to user code via Thread.current[:aj_temporal_idempotency_key] or a simple block accessor).

3.6 Cancellation
	•	ActiveJob::Temporal.cancel(job_id) will:
	•	Build workflow handle from the deterministic workflow_id.
	•	Call handle.cancel.
	•	Activity should heartbeat (v0.1: optional but recommended); upon cancel, abort promptly.

3.7 Transactional Enqueue
	•	Adapter declares enqueue_after_transaction_commit? => true. Rails will call it post-commit.

⸻

4. Error Semantics

4.1 Activity-Level Mapping
	•	If job raises:
	•	Exception class ∈ any discard_on → re-raise ApplicationError(non_retryable: true, cause: e).
	•	Exception class ∈ any retry_on (or subclass) → re-raise original or ApplicationError (retryable). Temporal will retry per policy.
	•	Otherwise: retryable once (default maximum_attempts = 1) unless job defined retry_on.

4.2 Adapter-Level Failures
	•	Client connection errors: log error; raise ActiveJob::EnqueueError so Rails surfaces it.
	•	Serialization errors: raise ActiveJob::SerializationError before starting Workflow.

⸻

5. Configuration

# config/initializers/activejob_temporal.rb
ActiveJob::Temporal.configure do |c|
  c.target     = ENV.fetch("TEMPORAL_TARGET", "127.0.0.1:7233")
  c.namespace  = ENV.fetch("TEMPORAL_NAMESPACE", "default")
  c.task_queue_prefix = ENV.fetch("AJ_TEMPORAL_PREFIX", nil) # optional "app-"
  c.default_activity_timeout = 15.minutes
  c.default_retry_initial_interval = 30.seconds
  c.default_retry_backoff = 2.0
  c.default_retry_max_attempts = 1
  c.logger = Rails.logger
  c.enable_tracing = true
end

Task queue resolution:

resolve_task_queue(job):
  base = job.queue_name || "default"
  prefix = config.task_queue_prefix
  "#{prefix}#{base}"


⸻

6. Observability & Metadata

6.1 Logging
	•	Info logs:
	•	Enqueued workflow (class, queue, job_id, workflow_id)
	•	Activity start/finish with duration
	•	Retry attempts (attempt, error)
	•	Cancellation requested/acknowledged
	•	Error logs include workflow_id, run_id, exception class & message.

6.2 Tracing (optional v0.1)
	•	If enable_tracing:
	•	Create spans for AjWorkflow.execute and AjRunnerActivity.execute.
	•	Inject workflow_id, run_id, task_queue as span attributes.

6.3 Search Attributes (Visibility)
	•	Attach on workflow start:
	•	ajClass (keyword) — job class name
	•	ajQueue (keyword) — queue name
	•	ajJobId (keyword) — ActiveJob job_id
	•	ajEnqueuedAt (datetime)
	•	Optional: ajTenantId if present on job (best-effort)

⸻

7. Code Layout

activejob-temporal/
  lib/
    activejob/
      temporal.rb                  # entrypoint + configuration
      temporal/version.rb
      temporal/client.rb           # client memoization
      temporal/adapter.rb          # QueueAdapters::TemporalAdapter
      temporal/payload.rb          # AJ args serialize/deserialize
      temporal/retry_mapper.rb     # AJ DSL → RetryPolicy
      temporal/cancel.rb           # .cancel(job_id)
      temporal/logger.rb
      temporal/search_attributes.rb
    activejob/temporal/workflows/
      aj_workflow.rb               # Temporal workflow (one)
    activejob/temporal/activities/
      aj_runner_activity.rb        # Temporal activity (one)
  bin/
    temporal-worker                # boots worker with registrations
  spec/                            # RSpec or Minitest
  activejob-temporal.gemspec
  README.md
  CHANGELOG.md
  LICENSE


⸻

8. Core Implementation Sketches (pseudocode)

8.1 Adapter

module ActiveJob
  module QueueAdapters
    class TemporalAdapter < AbstractAdapter
      def enqueue(job)        = start(job, at: nil)
      def enqueue_at(job, ts) = start(job, at: Time.at(ts))

      def enqueue_after_transaction_commit? = true

      private
      def start(job, at:)
        payload = ActiveJob::Temporal::Payload.from_job(job, scheduled_at: at)
        client  = ActiveJob::Temporal.client
        client.start_workflow(
          ActiveJob::Temporal::Workflows::AjWorkflow,
          payload,
          id: workflow_id(job),
          task_queue: task_queue(job),
          id_conflict_policy: :reject,
          search_attributes: ActiveJob::Temporal::SearchAttributes.for(job)
        )
      end

      def workflow_id(job) = "ajwf:#{job.class.name}:#{job.job_id}"
      def task_queue(job)
        base = job.queue_name || "default"
        prefix = ActiveJob::Temporal.config.task_queue_prefix
        "#{prefix}#{base}"
      end
    end
  end
end

8.2 Workflow

class ActiveJob::Temporal::Workflows::AjWorkflow < Temporalio::Workflow::Definition
  def execute(payload)
    if payload.scheduled_at && payload.scheduled_at > Temporalio::Workflow.now
      Temporalio::Workflow.sleep(payload.scheduled_at - Temporalio::Workflow.now)
    end

    Temporalio::Workflow.execute_activity(
      ActiveJob::Temporal::Activities::AjRunnerActivity,
      payload,
      start_to_close_timeout: ActiveJob::Temporal.config.default_activity_timeout,
      retry: ActiveJob::Temporal::RetryMapper.for(payload.job_class)
    )
  end
end

8.3 Activity

class ActiveJob::Temporal::Activities::AjRunnerActivity < Temporalio::Activity::Definition
  def execute(payload)
    job_class = payload.job_class.constantize
    args      = ActiveJob::Temporal::Payload.deserialize_args(payload)
    job       = job_class.new

    Thread.current[:aj_temporal_idempotency_key] =
      "#{Temporalio::Activity.info.workflow_id}/runner"

    job.perform(*args)
  rescue => e
    mapper = ActiveJob::Temporal::RetryMapper
    if mapper.discard_exception?(job_class, e)
      raise Temporalio::Activity::ApplicationError.new(
        e.message, non_retryable: true, cause: e
      )
    else
      raise e
    end
  ensure
    Thread.current[:aj_temporal_idempotency_key] = nil
  end
end

8.4 Retry Mapper

module ActiveJob::Temporal::RetryMapper
  def self.for(job_class)
    # inspect job_class.retry_on / discard_on metadata
    # defaults if none present
    {
      initial_interval: ActiveJob::Temporal.config.default_retry_initial_interval,
      backoff_coefficient: ActiveJob::Temporal.config.default_retry_backoff,
      maximum_attempts: attempts_for(job_class) # 1 if none
    }.merge(non_retryable_error_types: discard_types_for(job_class))
  end

  def self.discard_exception?(job_class, ex)
    discard_types_for(job_class).any? { |t| ex.is_a?(constantize(t)) }
  end
end

8.5 Client & Worker Bootstrap

# lib/activejob/temporal/client.rb
module ActiveJob::Temporal
  def self.client
    @client ||= Temporalio::Client.connect(
      config.target,
      namespace: config.namespace
    )
  end
end

# bin/temporal-worker
client = ActiveJob::Temporal.client
worker = Temporalio::Worker.new(
  client: client,
  task_queue: ENV.fetch("AJ_TEMPORAL_WORKER_QUEUE", "default"),
  workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
  activities: [ActiveJob::Temporal::Activities::AjRunnerActivity],
  shutdown_signals: %w[SIGINT SIGTERM],
  max_concurrent_activity_task_executions: ENV.fetch("AJ_TEMPORAL_MAX_ACT", 100).to_i
)
worker.run


⸻

9. Security & Safety
	•	Do not serialize sensitive objects directly. Use ActiveJob::Arguments (GlobalID) only.
	•	Add a max payload size check (raise SerializationError > e.g. 250KB unless overridden).
	•	Disallow non-JSON serializable types by default; provide hook to customize.
	•	Never use real time or randomness in workflow; all real I/O must be in the activity.

⸻

10. Testing Requirements

Unit
	•	Adapter:
	•	Builds expected workflow_id, task_queue
	•	Calls client.start_workflow with expected payload & search attributes
	•	Payload (de)serialization round-trip with AJ args & GlobalID
	•	RetryMapper:
	•	Maps retry_on/discard_on combinations correctly
	•	AjRunnerActivity:
	•	Calls job perform with args
	•	Maps discard_on to non-retryable ApplicationError

Integration (with test Temporal server)
	•	perform_later triggers workflow → activity → job execution
	•	set(wait: …) delays execution (assert time window)
	•	Retry on transient error hits multiple attempts then succeeds
	•	Cancellation stops activity (if heartbeating) and workflow completes as canceled
	•	Visibility: search attributes present

⸻

11. Documentation (README v0.1)
	•	Install, Configure, Run worker
	•	Quick start (adapter registration, example job)
	•	Scheduling, Retries, Cancellation
	•	Observability (Search Attributes, logs)
	•	Limitations (no Update/Signals/Child WF in v0.1)
	•	Migration notes (from Sidekiq/Async/Resque—high level)

⸻

12. Versioning & Changelog
	•	SemVer
	•	0.1.0 = initial release
	•	CHANGELOG entries for each fix/feature

⸻

13. Acceptance Criteria (Go/No-Go)
	•	✅ perform_later starts a Temporal workflow with expected IDs/metadata.
	•	✅ set(wait:) delays execution using Workflow.sleep (no worker thread blocked).
	•	✅ retry_on/discard_on are honored (activity retries and non-retryable mapping).
	•	✅ Duplicate enqueue (same job_id) is rejected (no duplicate workflows).
	•	✅ ActiveJob::Temporal.cancel(job_id) cancels a running workflow.
	•	✅ Search attributes (ajClass, ajQueue, ajJobId, ajEnqueuedAt) are persisted.
	•	✅ Works on Ruby 4.0+ and Rails 7.2+ with temporalio 1.4.1+.

⸻

Next Releases (for context)
	•	v0.2: Temporal Schedules integration (mass scheduling), OpenTelemetry interceptor, per-queue rate limiting.
	•	v0.3: Signals/Queries/Updates API exposure for jobs (opt-in), child workflows.
	•	v1.0: Stable API, migration guide, Rails generators, full docs & samples.

⸻

This spec is intentionally strict: if an implementation matches it line-by-line, you’ll have a production-ready, minimal, durable ActiveJob adapter backed by Temporal with safe scheduling and retries.