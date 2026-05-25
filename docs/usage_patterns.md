# Usage Patterns

This guide covers ActiveJob-facing APIs that are useful after the basic adapter and worker setup are working. Keep configuration details in [Configuration Reference](configuration_reference.md) and worker process details in [Worker Setup](worker_setup.md).

## Scheduled Jobs

Use ActiveJob's standard `set` API for one-off delayed execution:

```ruby
SendInvoiceJob.set(wait: 5.minutes).perform_later(invoice.id)
SendInvoiceJob.set(wait_until: Time.zone.now + 1.hour).perform_later(invoice.id)
```

The adapter starts a Temporal workflow immediately. The workflow sleeps durably until the scheduled time, then runs the job activity. For cron-style recurring work, use [Recurring Jobs](recurring_jobs.md).

## Conditional Enqueueing

Use `perform_later_if` when a job should be enqueued only if a runtime condition passes. The condition receives the job arguments as an array. If it returns a falsey value, no workflow is started and the method returns `nil`.

```ruby
ProcessAccountJob.perform_later_if(
  ->(arguments) { Account.find(arguments.first).active? },
  account.id
)
```

You can also reference a public class method:

```ruby
class ProcessAccountJob < ApplicationJob
  def self.should_enqueue?(arguments)
    Account.find(arguments.first).active?
  end

  def perform(account_id)
    ProcessAccount.call(account_id)
  end
end

ProcessAccountJob
  .set(queue: :low_priority)
  .perform_later_if(:should_enqueue?, account.id)
```

Pass only developer-defined symbols, strings, or callables. Do not derive condition names from request params or other user-controlled input, because symbol and string conditions call public methods on the job class.

## Bulk Enqueueing

Use `ActiveJob::Temporal.enqueue_batch` to enqueue prepared jobs and inspect per-job results. Each item can be a job instance, or a hash with `:job` and optional `:scheduled_at`.

```ruby
jobs = [
  SendInvoiceJob.new(invoice.id),
  { job: SendInvoiceJob.new(other_invoice.id), scheduled_at: 10.minutes.from_now }
]

result = ActiveJob::Temporal.enqueue_batch(jobs, concurrency: 4)

result.success_count
result.duplicate_count
result.failures.map(&:to_h)
```

Bulk enqueue starts one workflow per job. It is not a single Temporal multi-start RPC.

## Choosing An Orchestration Pattern

Use the smallest primitive that matches ownership and data flow:

| Pattern | Use when | Execution shape |
| --- | --- | --- |
| `set(chain:)` | One job should run after another in the same workflow | Linear sequence. Each step receives the previous result. |
| `set(child_workflows:)` | A parent job owns follow-up work and should wait for child results | Parent-owned fan-out. Parent cancellation requests child cancellation. |
| `set(depends_on:)` | A job was enqueued independently and another job should wait for it | External gate. The dependent workflow waits before its job activity starts. |

These primitives intentionally stop short of a general DAG API. Model branching work as child workflows when the parent owns the children, or as independently enqueued jobs with dependency gates when jobs should keep separate lifecycle ownership.

## Job Chaining

Use `set(chain:)` when one job should run after another in the same Temporal workflow. Each step runs as a separate `AjRunnerActivity`, and each step receives the previous job's return value as its single argument.

```ruby
class BuildInvoicePayloadJob < ApplicationJob
  def perform(invoice_id)
    invoice = Invoice.find(invoice_id)
    { id: invoice.id, total_cents: invoice.total_cents }
  end
end

class SendInvoicePayloadJob < ApplicationJob
  queue_as :mailers

  def perform(invoice_payload)
    InvoiceMailer.invoice_ready(invoice_payload).deliver_now
    invoice_payload.fetch(:id)
  end
end

class MarkInvoiceSentJob < ApplicationJob
  def perform(invoice_id)
    Invoice.find(invoice_id).update!(sent_at: Time.current)
  end
end

BuildInvoicePayloadJob
  .set(chain: [ActiveJob::Temporal.job(SendInvoicePayloadJob, queue: :mailers), MarkInvoiceSentJob])
  .perform_later(invoice.id)
```

Failures stop the chain. Chain return values are stored in Temporal history before being passed to the next step, so prefer small primitives, IDs, and compact hashes. ActiveJob chain steps use the chained job class's retry, timeout, rate-limit metadata, and queue routing. Run workers for every task queue used by the root job and chained steps.

Use a bare job class when a chain step should use its class defaults. Use `ActiveJob::Temporal.job(JobClass, queue:, priority:)` when a chain step needs per-step ActiveJob routing options. Chain descriptors intentionally support only `queue` and `priority`; scheduling options such as `wait` do not apply because the chain is already owned by the root workflow.

`JobClass.set(...)` remains accepted in `chain:` for compatibility with existing apps, but it depends on Rails' `ActiveJob::ConfiguredJob` internals. The adapter logs `active_job_configured_job_private_api` with `feature: "chain"` when that fallback is used. Prefer `ActiveJob::Temporal.job(...)` for new chain entries.

## External Temporal Steps

Use `ActiveJob::Temporal.activity` and `ActiveJob::Temporal.workflow` in `chain:` when a Rails workflow should call Temporal work owned by another service:

```ruby
CheckoutJob.set(
  chain: [
    BuildPaymentRequestJob,
    ActiveJob::Temporal.activity(
      "payments.AuthorizePayment",
      task_queue: "payments-kotlin",
      start_to_close_timeout: 30.seconds
    ),
    ActiveJob::Temporal.workflow(
      "inventory.ReserveInventoryWorkflow",
      task_queue: "inventory-kotlin",
      run_timeout: 5.minutes
    ),
    CompleteCheckoutJob
  ]
).perform_later(order.id)
```

`task_queue:` is required for external steps. Activity and workflow type names are passed to Temporal as strings. Each external chain step receives the previous step result as its input and returns its Temporal result to the next step.

External inputs and results must be JSON-compatible values, and they are still recorded in Temporal history. Keep them small: pass IDs, strings, numbers, arrays, and compact hashes instead of models, GlobalID objects, binary data, or large payloads.

External steps use Temporal options directly. Configure timeouts and retries with Temporal options such as `start_to_close_timeout`, `run_timeout`, and `retry_policy`. Rails `retry_on`, `discard_on`, ActiveJob middleware, and ActiveJob argument serialization do not run for external steps.

External workflow refs can also be used in `child_workflows:`:

```ruby
BuildOrderPlanJob.set(
  child_workflows: [
    SendReceiptJob,
    ActiveJob::Temporal.workflow(
      "fulfillment.PrepareShipmentWorkflow",
      task_queue: "fulfillment-kotlin"
    )
  ]
).perform_later(order.id)
```

External child workflows receive the parent job result as their input and contribute their Temporal result to the parent's `child_results` collection. Use `ActiveJob::Temporal.workflow` for external children; `ActiveJob::Temporal.activity` is only valid in `chain:`.

## Stable Temporal Identity

Use class-level workflow identity when another service needs a stable contract for work owned by a Rails job. The public workflow name is a static operation name. The workflow ID is still a per-execution identifier.

```ruby
class ChargePaymentJob < ApplicationJob
  temporal_workflow_name "payments.charge_payment"
  temporal_workflow_id do |payment_id|
    "payment:#{payment_id}"
  end

  def perform(payment_id)
    ChargePayment.call(payment_id)
  end
end
```

`temporal_workflow_name` is metadata for shared contracts and payload inspection. It does not change the Ruby worker's registered Temporal workflow type, which remains the adapter workflow. `temporal_workflow_id` changes the per-execution workflow ID and receives the same arguments as `perform`.

For jobs that only need class-name-free IDs based on the ActiveJob job ID, use a prefix:

```ruby
class SendInvoiceJob < ApplicationJob
  temporal_workflow_name "billing.send_invoice"
  temporal_workflow_id_prefix "invoice"
end
```

That job starts workflows like `invoice:<job_id>` instead of `ajwf:SendInvoiceJob:<job_id>`. Jobs without these declarations keep the default `ajwf:<ClassName>:<job_id>` IDs.

Cross-service references should document both values:

```text
workflow name: payments.charge_payment
workflow ID:   payment:<payment_id>
task queue:    payments
```

Use the workflow name as the stable operation contract and the workflow ID shape to signal, inspect, or depend on one execution. Do not use one static workflow ID for ordinary jobs, because Temporal workflow IDs identify executions. Static workflow IDs are only appropriate for singleton workflows.

## Child Workflows

Use `set(child_workflows:)` when a parent job should start separate ActiveJob-backed or external Temporal workflows and wait for their results. The parent job runs first. Each child receives the parent result as its single input and returns its result to the parent.

```ruby
class BuildInvoiceBatchJob < ApplicationJob
  def perform(batch_id)
    InvoiceBatch.find(batch_id).invoice_ids
  end
end

class SendInvoiceJob < ApplicationJob
  queue_as :mailers

  def perform(invoice_ids)
    Invoice.where(id: invoice_ids).find_each do |invoice|
      InvoiceMailer.invoice_ready(invoice).deliver_now
    end
    invoice_ids.size
  end
end

BuildInvoiceBatchJob
  .set(child_workflows: [ActiveJob::Temporal.job(SendInvoiceJob, queue: :mailers, tags: %w[invoices])])
  .perform_later(batch.id)
```

Child workflow IDs are owned by the parent and use the child job class plus a deterministic child job ID derived from the parent job ID. Parent cancellation requests cancellation of started children, and parent close requests child cancellation instead of abandoning the child workflow.

Use a bare job class when a child workflow should use its class defaults. Use `ActiveJob::Temporal.job(ChildJob, queue:, priority:, tags:)` when a child needs specific routing or search metadata. Child descriptors support `queue`, `priority`, and `tags`.

`JobClass.set(...)` remains accepted in `child_workflows:` for compatibility with existing apps, but it depends on Rails' `ActiveJob::ConfiguredJob` internals. The adapter logs `active_job_configured_job_private_api` with `feature: "child_workflows"` when that fallback is used. Prefer `ActiveJob::Temporal.job(...)` for new child workflow entries.

When child workflows are present, the parent result becomes a collection:

```ruby
{
  "parent_result" => invoice_ids,
  "child_results" => [
    {
      "job_class" => "SendInvoiceJob",
      "job_id" => "#{parent_job_id}:child:1",
      "workflow_id" => "ajwf:SendInvoiceJob:#{parent_job_id}:child:1",
      "result" => 25
    }
  ]
}
```

If `set(chain:)` is also configured, the first chain step receives this collection as its single argument. ActiveJob children preserve their job class retry policy, timeouts, rate limits, queue routing, and search metadata. External workflow refs use the Temporal options supplied to `ActiveJob::Temporal.workflow`.

## Job Dependencies

Use `set(depends_on:)` when a separately enqueued job should finish before another job starts. The dependent workflow checks dependency status through a Temporal activity, sleeps durably between checks, then runs the job activity once every dependency has completed.

```ruby
export_job = ExportReportJob.perform_later(report.id)

EmailReportJob
  .set(depends_on: export_job)
  .perform_later(report.id)
```

Dependencies can be enqueued ActiveJob instances, job IDs, or explicit hashes:

```ruby
EmailReportJob.set(depends_on: export_job).perform_later(report.id)
EmailReportJob.set(depends_on: export_job.job_id).perform_later(report.id)
EmailReportJob.set(depends_on: { job_class: ExportReportJob, job_id: export_job.job_id }).perform_later(report.id)
EmailReportJob.set(depends_on: { workflow_id: "custom-export-workflow" }).perform_later(report.id)
```

When only a job ID is provided, dependency lookup uses the `ajJobId` Temporal search attribute. This works with the default search attribute setup. If search attributes are disabled, pass an enqueued job instance or explicit `workflow_id`. With a custom `workflow_id_generator`, prefer the enqueued job instance or explicit `workflow_id` forms.

Multiple dependencies are supported:

```ruby
archive_job = ArchiveReportJob.perform_later(report.id)
notify_job = NotifyAuditJob.perform_later(report.id)

FinalizeReportJob
  .set(depends_on: [archive_job, notify_job])
  .perform_later(report.id)
```

By default, a failed, canceled, terminated, or timed-out dependency fails the dependent workflow before its job activity starts. Use `on_dependency_failure: :ignore` when the dependent job should continue after dependency failures:

```ruby
CleanupReportJob
  .set(depends_on: [archive_job, notify_job], on_dependency_failure: :ignore)
  .perform_later(report.id)
```

Missing dependencies are treated as dependency failures after a bounded retry window. This prevents typoed IDs or expired workflow visibility records from leaving the dependent workflow waiting forever.

## Per-Job Timeouts

Use `temporal_options` when one job needs activity timeouts that differ from global defaults:

```ruby
class DataProcessingJob < ApplicationJob
  temporal_options(
    start_to_close_timeout: 2.hours,
    heartbeat_timeout: 30.seconds
  )

  def perform(batch_id)
    Record.where(batch_id: batch_id).find_each do |record|
      process_record(record)
      Temporalio::Activity::Context.current.heartbeat
    end
  end
end
```

Available timeout options:

- `start_to_close_timeout`: maximum execution time for one activity attempt.
- `heartbeat_timeout`: maximum interval between heartbeats.
- `schedule_to_start_timeout`: maximum wait before the activity starts.
- `schedule_to_close_timeout`: total time including all retries.

Timeout values can be integers in seconds or `ActiveSupport::Duration` objects. At least one of `start_to_close_timeout` or `schedule_to_close_timeout` must be specified through job options or global configuration. Long-running cancellable jobs should use `heartbeat_timeout` and call `Temporalio::Activity::Context.current.heartbeat` regularly.

## Rate Limiting

Use `rate_limit` on a job class for per-job throughput and `config.global_rate_limit` for a process-wide rule that applies to every job payload.

```ruby
ActiveJob::Temporal.configure do |config|
  config.rate_limiter = ActiveJob::Temporal::RateLimiters::Memory.new
  config.global_rate_limit = { limit: 1_000, per: :minute }
end

class ApiSyncJob < ApplicationJob
  rate_limit 100, per: :second, key: "external-api"

  def perform(account_id)
    ExternalApi.sync_account(account_id)
  end
end
```

The built-in memory limiter is process-local. Use a shared backend for multi-process or multi-host workers. Custom limiters can respond to `wait_time_for(rate_limits)` or `call(rate_limits)` and return `0` to run now, or a finite positive number of seconds to wait.

Rate-limit keys stay plaintext in workflow payloads, including when payload encryption is enabled. Do not put secrets or customer data in custom keys.

## Cancellation And Status

Cancel one running job by ActiveJob class and job ID:

```ruby
ActiveJob::Temporal.cancel(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
```

Terminate groups of running jobs by search attributes:

```ruby
ActiveJob::Temporal.cancel_all(SendInvoiceJob)
ActiveJob::Temporal.cancel_where(ajQueue: "low_priority")
ActiveJob::Temporal.cancel_where(ajClass: "ReportJob", ajTenantId: 123)
```

`cancel` finds the workflow by `ajClass` and `ajJobId`, uses the discovered workflow ID, returns `false` when the workflow already completed, and raises `ActiveJob::Temporal::WorkflowNotFoundError` when no matching workflow exists. Batch cancellation lists running workflows with Temporal visibility pagination, calls `handle.terminate` for each match, and returns `{ terminated:, failed:, errors: }`.

Long-running jobs should heartbeat so Temporal can deliver cancellation promptly:

```ruby
class LongRunningJob < ApplicationJob
  def perform
    100.times do |index|
      Temporalio::Activity::Context.current.heartbeat
      process_chunk(index)
    end
  end
end
```

Inspect job state without opening Temporal UI:

```ruby
status = ActiveJob::Temporal.status(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")

ActiveJob::Temporal.running?(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
ActiveJob::Temporal.completed?(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
ActiveJob::Temporal.failed?(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
```

`status` returns `nil` when no workflow exists for the given job ID. Predicates return `false` for missing jobs. `attempt` and `last_failure` are best-effort details from pending activities, so closed workflows may return `nil` for both.

## Signals, Queries, And Updates

Signals mutate workflow-owned state. Queries read it:

```ruby
job_id = "550e8400-e29b-41d4-a716-446655440000"

ActiveJob::Temporal.signal(ImportJob, job_id, :pause, "maintenance")
ActiveJob::Temporal.query(ImportJob, job_id, :paused)
ActiveJob::Temporal.signal(ImportJob, job_id, :resume)
```

Built-in signals:

- `pause` marks the workflow paused at workflow checkpoints before the job activity starts and between workflow-owned waits.
- `resume` clears the paused state.

Built-in queries:

- `state` returns workflow-owned state such as phase, pause state, job class, job ID, queue name, and received signals.
- `paused` returns a boolean.
- `pause_reason` returns the latest pause reason when one was provided.
- `phase` returns the workflow phase.
- `signals` returns the latest received signal metadata by signal name.

Jobs can declare custom workflow signal, query, and update handlers:

```ruby
class ImportJob < ApplicationJob
  temporal_signal :set_progress do |state, completed, total|
    state["progress"] = {
      "completed" => completed,
      "total" => total,
      "percentage" => total.to_i.zero? ? 0 : ((completed.to_f / total) * 100).round
    }
  end

  temporal_query :progress do |state|
    state["progress"] || { "completed" => 0, "total" => nil, "percentage" => 0 }
  end

  temporal_update :set_checkpoint do |state, checkpoint|
    state["checkpoint"] = checkpoint
  end

  def perform(account_id)
    import_account(account_id)
  end
end

ActiveJob::Temporal.signal(ImportJob, job_id, :set_progress, 450, 1_000)
ActiveJob::Temporal.query(ImportJob, job_id, :progress)
ActiveJob::Temporal.update(ImportJob, job_id, :set_checkpoint, "users:450")
```

Custom handlers run inside Temporal workflow code. Keep them deterministic: update only the provided state hash, avoid database calls, network calls, random values, process time, and other I/O. Built-in names (`pause`, `resume`, `state`, `paused`, `pause_reason`, `phase`, and `signals`) are reserved.

Pause and resume do not suspend Ruby code already executing inside `perform`, and they do not interrupt an active Temporal timer. Running activities need cooperative behavior such as heartbeats, cancellation checks, or application-level checkpoint state.
