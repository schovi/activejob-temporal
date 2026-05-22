# activejob-temporal

> Temporal-powered adapter for Rails ActiveJob.

[![Gem Version](https://badge.fury.io/rb/activejob-temporal.svg)](https://badge.fury.io/rb/activejob-temporal)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![CI](https://github.com/schovi/activejob-temporal/actions/workflows/ci.yml/badge.svg)](https://github.com/schovi/activejob-temporal/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/schovi/activejob-temporal/branch/main/graph/badge.svg)](https://codecov.io/gh/schovi/activejob-temporal)

⚠️ This gem is under active development. Expect rapid iteration and potential breaking changes until v1.0.0.

## Introduction

**activejob-temporal** provides a production-ready ActiveJob adapter backed by [Temporal's](https://temporal.io) durable execution engine. This integration enables Rails applications to leverage Temporal's reliability, observability, and fault-tolerance capabilities with minimal code changes.

Instead of relying on Redis, PostgreSQL, or other queue backends, your background jobs are executed as Temporal workflows and activities. This gives you:

- **Durable execution:** Jobs survive process restarts, infrastructure failures, and deployment rollouts
- **Built-in fault tolerance:** Temporal's battle-tested retry policies handle transient failures automatically
- **Superior observability:** Use Temporal UI and search attributes to track, filter, and debug job execution in real time
- **Custom job tags:** Use `set(tags:)` to add searchable tags to Temporal workflows
- **Simplified operations:** No separate queue infrastructure needed—Temporal handles persistence, scheduling, and coordination

The gem is designed as a **drop-in replacement** for existing ActiveJob adapters like Sidekiq or Resque. Change your queue adapter to `:temporal`, configure the Temporal client, and your jobs gain all the benefits of durable execution.

## Features

- ✅ **Immediate job execution:** Use `MyJob.perform_later(args)` to enqueue jobs for instant execution
- ✅ **Scheduled execution:** Use `MyJob.set(wait: 5.minutes).perform_later(args)` or `MyJob.set(wait_until: Time.zone.now + 1.hour).perform_later(args)` for delayed jobs
- ✅ **Recurring jobs:** Declare cron schedules on job classes and register them through Temporal Schedules
- ✅ **Conditional enqueueing:** Use `MyJob.perform_later_if(condition, args)` to skip jobs when no work is needed
- ✅ **Job chaining:** Use `MyJob.set(chain: [NextJob]).perform_later(args)` to run sequential activities in one workflow
- ✅ **Job dependencies:** Use `MyJob.set(depends_on: parent_job).perform_later(args)` to wait for independently enqueued jobs
- ✅ **Retry mapping:** ActiveJob `retry_on` declarations automatically map to Temporal retry policies with exponential backoff
- ✅ **Discard mapping:** `discard_on` maps to non-retryable errors, preventing wasted retry attempts
- ✅ **Per-job timeout configuration:** Configure activity timeouts per job using `temporal_options` class method
- ✅ **Rate limiting:** Enforce global and per-job throughput limits through a pluggable limiter backend
- ✅ **Job cancellation:** Cancel in-flight jobs via `ActiveJob::Temporal.cancel(JobClass, job_id)` API
- ✅ **Signals and queries:** Send workflow signals and query workflow-owned state
- ✅ **Search attributes:** Filter and debug jobs in Temporal UI using job class, queue, job ID, tenant ID, custom tags, and enqueue timestamp
- ✅ **Transactional enqueue:** Jobs automatically defer enqueue until the current database transaction commits (via `enqueue_after_transaction_commit?`)
- ✅ **GlobalID support:** Seamless serialization of ActiveRecord models and other GlobalID-compatible objects
- ✅ **Payload serialization options:** Keep JSON defaults or encode job execution payloads with MessagePack or Marshal
- ✅ **Configurable timeouts and retries:** Fine-tune activity timeouts, retry intervals, and backoff coefficients globally
- ✅ **Structured logging:** JSON logs for integration with observability infrastructure
- ✅ **Optional payload encryption:** Encrypt job execution payloads with AES-256-GCM while preserving deterministic workflow metadata

## Installation

**Requirements:**
- Ruby >= 4.0
- Rails >= 7.2 (ActiveJob 7.2+ and 8.x)
- Temporal cluster (self-hosted or [Temporal Cloud](https://temporal.io/cloud))

Add this line to your application's Gemfile:

```ruby
gem "activejob-temporal"
```

And then execute:

```bash
bundle install
```

The gem will automatically install dependencies:
- `activejob` (>= 7.2, < 9)
- `activemodel` (>= 7.2, < 9)
- `concurrent-ruby` (~> 1.1)
- `globalid` (>= 0.3)
- `listen` (~> 3.9)
- `temporalio` (>= 1.4.0, < 1.5) — the Temporal Ruby SDK

Ruby 4 compatibility is supported on Temporal Ruby SDK 1.4.x and contract-tested against 1.4.0 and 1.4.1 in CI.

## Quick Start

This guide walks you through setting up activejob-temporal from scratch.

### Step 1: Configure the Temporal adapter

Tell ActiveJob to use the Temporal adapter in your Rails application:

```ruby
# config/application.rb (or config/environments/production.rb)
config.active_job.queue_adapter = :temporal
```

### Step 2: Configure the Temporal client

Create an initializer to configure the Temporal client connection:

```ruby
# config/initializers/activejob_temporal.rb
ActiveJob::Temporal.configure do |config|
  config.target = ENV.fetch("ACTIVEJOB_TEMPORAL_TARGET", "127.0.0.1:7233")
  config.namespace = ENV.fetch("ACTIVEJOB_TEMPORAL_NAMESPACE", "default")
  config.task_queue_prefix = ENV.fetch("ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX", nil)

  # Optional: customize timeouts and retries
  config.default_activity_timeout = 15.minutes
  config.default_retry_initial_interval = 30.seconds
  config.default_retry_backoff = 2.0
  config.default_retry_max_attempts = 1
end
```

See the [Configuration](#configuration) section below for all available options.

### Step 3: Register Search Attributes (one-time setup)

Search attributes allow you to filter and search jobs in the Temporal UI. Register them once per Temporal cluster:

```bash
tctl admin cluster add-search-attributes \
  --name ajClass --type Keyword \
  --name ajQueue --type Keyword \
  --name ajJobId --type Keyword \
  --name ajEnqueuedAt --type Datetime \
  --name ajTenantId --type Int \
  --name ajTags --type KeywordList
```

If using Temporal Cloud or `temporal` CLI instead of `tctl`, adjust the command accordingly. See [Observability](#observability) for details.

### Step 4: Define a job

Create a standard ActiveJob job class:

```ruby
# app/jobs/send_invoice_job.rb
class SendInvoiceJob < ApplicationJob
  queue_as :billing

  retry_on SomeTransientError, wait: 60.seconds, attempts: 5
  discard_on SomeFatalError

  def perform(invoice_id)
    invoice = Invoice.find(invoice_id)
    InvoiceMailer.invoice_ready(invoice).deliver_now
  end
end
```

### Step 5: Enqueue a job

Enqueue jobs as you normally would with ActiveJob:

```ruby
# Immediate execution
SendInvoiceJob.perform_later(invoice.id)

# Scheduled execution
SendInvoiceJob.set(wait: 5.minutes).perform_later(invoice.id)

# Conditional execution
SendInvoiceJob.perform_later_if(
  ->(arguments) { Invoice.find(arguments.first).ready? },
  invoice.id
)
```

### Step 6: Start a Temporal worker

The worker polls Temporal for jobs and executes them. Start the worker using the provided executable:

```bash
ACTIVEJOB_TEMPORAL_TARGET=localhost:7233 \
ACTIVEJOB_TEMPORAL_NAMESPACE=default \
ACTIVEJOB_TEMPORAL_TASK_QUEUE=billing \
bin/temporal-worker
```

Replace `billing` with the queue name your jobs use. You can run multiple workers polling different queues or the same queue for horizontal scaling.

See [Worker Deployment](#worker-deployment) for production deployment strategies.

### Step 7: Verify execution

1. Open the Temporal UI (default: [http://localhost:8233](http://localhost:8233))
2. Navigate to the `default` namespace (or your configured namespace)
3. You should see workflows named `ajwf:SendInvoiceJob:<job_id>` in the workflow list
4. Click on a workflow to view execution history, input/output, and retry attempts

## Configuration

The gem exposes a configuration DSL for customizing Temporal client behavior, timeouts, and retry policies. Call `ActiveJob::Temporal.configure` once at boot (typically in a Rails initializer).

### Configuration Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `target` | String | `"127.0.0.1:7233"` | Host and port of the Temporal frontend service. |
| `namespace` | String | `"default"` | Temporal namespace to use for workflows and activities. |
| `task_queue_prefix` | String or `nil` | `nil` | Optional prefix applied to every task queue name generated by the adapter. |
| `priority_task_queues` | Hash | `{}` | Optional mapping from numeric ActiveJob priority values to Temporal task queue names. |
| `tls_cert_path` | String or `nil` | `nil` | Client certificate file path for mTLS. Configure with `tls_key_path`. |
| `tls_key_path` | String or `nil` | `nil` | Client private key file path for mTLS. Configure with `tls_cert_path`. |
| `tls_server_root_ca_cert_path` | String or `nil` | `nil` | Optional root CA certificate file path for self-hosted Temporal TLS. |
| `tls_domain` | String or `nil` | `nil` | Optional SNI domain override for TLS verification. |
| `tls_cert_watch` | Boolean | `false` | Reload worker clients when configured TLS certificate files change. |
| `tls_reload_signal` | String | `"HUP"` | Signal name used by workers for manual TLS client reload. |
| `default_activity_timeout` | `ActiveSupport::Duration` | `15.minutes` | Default `start_to_close` timeout applied to activities that do not override it. Must be positive. |
| `default_retry_initial_interval` | `ActiveSupport::Duration` | `30.seconds` | Initial interval used by automatic retry logic before exponential backoff is applied. Must be positive. |
| `default_retry_backoff` | Float | `2.0` | Exponential factor used when calculating retry delays. |
| `default_retry_max_attempts` | Integer | `1` | Maximum retry attempts when a job does not specify its own `retry_on` rules. |
| `dead_letter_queue` | String or `nil` | `nil` | Optional Temporal task queue for parked dead letter workflows. |
| `dead_letter_after_attempts` | Integer or `nil` | `nil` | Optional retry attempt limit before a job is routed to the dead letter queue. |
| `logger` | `Logger` | `Rails.logger` or `Logger.new($stdout)` | Destination for adapter log output. |
| `audit_log` | Boolean | `false` | Enables structured job lifecycle audit events. |
| `audit_logger` | `Logger` or `nil` | `nil` | Optional destination for audit events. Falls back to `logger`. |
| `validation_level` | Symbol | `:strict` | Controls configuration validation: `:strict` raises, `:warn` logs warnings, `:none` skips validation. |
| `enable_tracing` | Boolean | `true` | Enables instrumentation hooks that emit OpenTelemetry spans. |
| `metrics_provider` | Symbol | `:none` | Metrics provider to use. Set to `:prometheus` to collect built-in Prometheus metrics. |
| `metrics_port` | Integer or `nil` | `nil` | Optional worker HTTP port for Prometheus metrics at `GET /metrics`. |
| `metrics_bind` | String | `"127.0.0.1"` | Bind address for the Prometheus metrics endpoint. |
| `middleware_chain` | `ActiveJob::Temporal::Middleware::Chain` | Empty chain | Ordered middleware chain used by `config.add_middleware` to wrap job execution inside activities. |
| `max_payload_size_kb` | Integer | `250` | Maximum allowed size (in kilobytes) for serialized job payloads before raising `ActiveJob::SerializationError`. |
| `payload_serializer` | Symbol | `:json` | Serializer for job execution payloads. Supports `:json`, `:message_pack`, `:msgpack`, and `:marshal`. |
| `encrypt_payload` | Boolean | `false` | Encrypt serialized job execution payloads before sending them to Temporal. |
| `encryption_key` | String, Hash, or `nil` | `nil` | Base64-encoded 32-byte AES-256-GCM payload encryption key, or `{ id:, key: }` metadata. Required when `encrypt_payload` is true. |
| `encryption_old_keys` | Array | `[]` | Previous encryption keys accepted for decryption during key rotation. Entries may be Base64 strings or `{ id:, key:, decrypt_until: }` hashes. |

### Example Configuration

```ruby
# config/initializers/activejob_temporal.rb
ActiveJob::Temporal.configure do |config|
  config.target = "temporal.example.com:7233"
  config.namespace = "production"
  config.task_queue_prefix = "rails-"
  config.priority_task_queues = { 10 => "high_priority", 90 => "low_priority" }
  config.default_activity_timeout = 30.seconds
  config.default_retry_initial_interval = 10.seconds
  config.default_retry_backoff = 1.5
  config.default_retry_max_attempts = 5
  config.dead_letter_queue = "failed_jobs"
  config.dead_letter_after_attempts = 3
  config.validation_level = :strict
  config.enable_tracing = false
  config.audit_log = true
  config.audit_logger = Logger.new("log/activejob_temporal_audit.log")
  config.metrics_provider = :prometheus
  config.metrics_port = 9394
  config.max_payload_size_kb = 512
  config.payload_serializer = :json
  config.encrypt_payload = true
  config.encryption_key = {
    id: "2026-05",
    key: ENV.fetch("ACTIVEJOB_TEMPORAL_ENCRYPTION_KEY")
  }
end
```

Use `validation_level = :warn` during gradual configuration migrations when boot should continue but warnings should be visible. Use `validation_level = :none` only for test setups that intentionally build partial configuration.

For detailed configuration documentation, see [Configuration Reference](docs/configuration_reference.md).

### Task Queue Routing

The adapter routes each job to the Temporal task queue named by ActiveJob's `queue_as` or `set(queue:)`. Configure `task_queue_prefix` when every generated task queue should be namespaced:

```ruby
class BillingJob < ApplicationJob
  queue_as :billing
end

ActiveJob::Temporal.configure do |config|
  config.task_queue_prefix = "prod-"
end

BillingJob.perform_later(account.id) # starts on Temporal task queue "prod-billing"
```

Configure `priority_task_queues` when numeric ActiveJob priorities from `set(priority:)` should override the normal queue route:

```ruby
ActiveJob::Temporal.configure do |config|
  config.priority_task_queues = {
    10 => "high_priority",
    90 => "low_priority"
  }
end

BillingJob.set(priority: 10).perform_later(account.id)
# starts on Temporal task queue "high_priority"
```

Priority keys must be integers because ActiveJob priorities are numeric. Run workers for each task queue you route to, for example `ACTIVEJOB_TEMPORAL_TASK_QUEUE=high_priority bundle exec temporal-worker`.

### Middleware

Register middleware to wrap job execution for tracing, metrics, custom logging, or tenant context:

```ruby
class TracingMiddleware
  def call(job)
    span = Tracer.start_span(job.class.name)
    yield
  ensure
    span&.finish
  end
end

ActiveJob::Temporal.configure do |config|
  config.add_middleware TracingMiddleware
end
```

Middleware runs inside the activity, after payload deserialization and before `job.perform`. The first registered middleware wraps the rest of the chain. See the [Middleware Guide](docs/middleware.md) for ordering and examples.

### Prometheus Metrics

Enable built-in Prometheus metrics when workers should expose job and worker telemetry:

```ruby
ActiveJob::Temporal.configure do |config|
  config.metrics_provider = :prometheus
  config.metrics_port = 9394
end
```

Then start the worker and scrape `GET /metrics`:

```bash
bundle exec temporal-worker --metrics-port 9394
curl http://localhost:9394/metrics
```

The exporter includes completed and failed job counters, job duration histograms, retry counters, and worker gauges. Enqueue counters and payload size histograms are recorded in the process that calls `perform_later`; scrape that process too if you need those series. See the [Metrics Guide](docs/metrics.md) for metric names, Prometheus scrape config, and the Grafana dashboard example.

### Audit Logging

Enable audit logging when you need a structured lifecycle trail for enqueue, start, completion, failure, and cancellation events:

```ruby
ActiveJob::Temporal.configure do |config|
  config.audit_log = true
  config.audit_logger = Logger.new("log/activejob_temporal_audit.log")
end
```

Audit events are JSON-formatted through the configured logger. Event names include `job.enqueued`, `job.started`, `job.completed`, `job.failed`, `job.cancelled`, and `schedule.created`. Events include correlation fields such as `workflow_id`, `run_id`, `job_class`, `job_id`, `queue`, `attempt`, and `worker_id` when available. Failure events include `error_class` and a SHA256 `error_fingerprint`, not raw exception messages or backtraces. Raw job arguments, payloads, and return values are not logged.

### Payload Serialization

JSON is the default payload format and remains the compatibility baseline. You can configure new enqueues to wrap the ActiveJob-normalized execution payload in a MessagePack or Marshal envelope:

```ruby
ActiveJob::Temporal.configure do |config|
  config.payload_serializer = :message_pack # aliases: :msgpack
end
```

`payload_serializer` controls only new payloads. Each non-JSON payload stores serializer metadata with the payload, so workers can read older JSON workflows and newer serialized workflows during a rolling deploy. Deploy workers that can read the new serializer before changing enqueueing processes to write it.

MessagePack requires the `msgpack` gem at runtime in any process that reads or writes MessagePack payloads. The gem is only a development dependency of `activejob-temporal`, so applications using `:message_pack` should add `gem "msgpack"` to their own Gemfile.

Marshal serializes the ActiveJob-normalized execution payload, not arbitrary job argument objects. Use it only when all writers, workers, and Temporal history readers are trusted and run compatible Ruby and application code. Marshal payloads are Ruby-specific and can break when classes or Ruby versions change.

### Payload Encryption

Enable payload encryption when job arguments or execution metadata should not be stored as plaintext in Temporal history:

```ruby
ActiveJob::Temporal.configure do |config|
  config.encrypt_payload = true
  config.encryption_key = {
    id: "2026-05",
    key: ENV.fetch("ACTIVEJOB_TEMPORAL_ENCRYPTION_KEY")
  }
end
```

Generate keys as Base64-encoded 32-byte values:

```ruby
SecureRandom.base64(32)
```

Encryption uses AES-256-GCM. New workflow payloads bind ciphertext to the Temporal namespace, workflow ID, and encryption key ID as authenticated data. The encrypted data contains job class, job ID, queue name, serialized arguments, execution counters, and workflow-control fields. Plaintext copies of workflow-control fields remain in the envelope so workflow replay does not depend on worker-local encryption keys.

Payload encryption does not hide all Temporal metadata. Default workflow IDs include job class and job ID, and search attributes can expose job class, queue, job ID, tenant ID, and tags. For privacy-sensitive workloads, configure a `workflow_id_generator` that does not embed sensitive identifiers, and disable or carefully constrain search attributes and custom tags.

For key rotation, deploy the new primary key and keep old keys configured until all workflows encrypted with old keys have finished or aged out of Temporal history:

```ruby
ActiveJob::Temporal.configure do |config|
  config.encrypt_payload = true
  config.encryption_key = {
    id: "2026-06",
    key: ENV.fetch("ACTIVEJOB_TEMPORAL_ENCRYPTION_KEY")
  }
  config.encryption_old_keys = [
    {
      id: "2026-05",
      key: ENV.fetch("ACTIVEJOB_TEMPORAL_OLD_ENCRYPTION_KEY"),
      decrypt_until: Time.utc(2026, 9, 1)
    }
  ]
end
```

Older version 1 envelopes without key IDs are still decryptable with Base64 string keys in `encryption_key` or `encryption_old_keys`. For version 2 envelopes, workers use `encrypted_key_id` to select one configured key and do not try every key. If you disable encryption for new jobs, keep `encryption_key` or the relevant `encryption_old_keys` configured on workers until every previously encrypted workflow has completed or aged out of Temporal history. Workers still need keys to decrypt already-started encrypted workflows.

## Conditional Enqueueing

Use `perform_later_if` when a job should only be enqueued if a runtime condition matches. The condition receives the job arguments as an array. If the condition returns a falsey value, the method returns `nil` and does not call the queue adapter.

```ruby
ProcessAccountJob.perform_later_if(
  ->(arguments) { Account.find(arguments.first).active? },
  account.id
)
```

You can also reference a public class method by symbol:

```ruby
class ProcessAccountJob < ApplicationJob
  def self.should_enqueue?(arguments)
    Account.find(arguments.first).active?
  end

  def perform(account_id)
    # Job logic
  end
end

ProcessAccountJob.perform_later_if(:should_enqueue?, account.id)
```

Configured jobs from `set` are supported, so options are preserved when the condition passes:

```ruby
ProcessAccountJob
  .set(queue: :low_priority)
  .perform_later_if(:should_enqueue?, account.id)
```

When the condition returns true, `perform_later_if` returns the normal ActiveJob instance returned by `perform_later`.

## Scheduled Jobs

Use ActiveJob's standard `set` method to schedule jobs for delayed execution:

```ruby
# Wait 5 minutes before executing
SendInvoiceJob.set(wait: 5.minutes).perform_later(invoice.id)

# Execute at a specific time
SendInvoiceJob.set(wait_until: Time.zone.now + 1.hour).perform_later(invoice.id)
```

Under the hood, the adapter starts a Temporal workflow that sleeps until the scheduled time before executing the activity.

## Job Chaining

Use `set(chain:)` when one job should run after another in the same Temporal workflow. Each chain step runs as a separate `AjRunnerActivity`, and each step receives the previous job's return value as its single argument:

```ruby
class BuildInvoicePayloadJob < ApplicationJob
  def perform(invoice_id)
    invoice = Invoice.find(invoice_id)
    { id: invoice.id, total_cents: invoice.total_cents }
  end
end

class SendInvoicePayloadJob < ApplicationJob
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
  .set(chain: [SendInvoicePayloadJob, MarkInvoiceSentJob])
  .perform_later(invoice.id)
```

Failures stop the chain. If `BuildInvoicePayloadJob` or `SendInvoicePayloadJob` raises after retries are exhausted, later jobs are not executed.

Chain return values are stored in Temporal history as activity results before being passed to the next step. Prefer small primitives, IDs, and compact hashes over large records or binary payloads.

Chain steps run with the chained job class's own retry, timeout, and rate-limit metadata. They also use that job's queue for the activity task queue. Use ActiveJob's configured-job form when a specific step should run on a different queue or priority-mapped task queue:

```ruby
BuildInvoicePayloadJob
  .set(chain: [SendInvoicePayloadJob.set(queue: :mailers, priority: 10)])
  .perform_later(invoice.id)
```

Run workers for every task queue used by the root job and its chained steps.

## Job Dependencies

Use `set(depends_on:)` when a separately enqueued job should finish before another job starts. The dependent workflow checks dependency status through a Temporal activity, sleeps durably between checks, then runs the job activity once every dependency has completed:

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

When only a job ID is provided, dependency lookup uses the `ajJobId` Temporal search attribute. This works with the default `enable_search_attributes = true` setup. If search attributes are disabled, pass an enqueued job instance or an explicit `workflow_id`. A `{ job_class:, job_id: }` hash also works with the default workflow ID format. With a custom `workflow_id_generator`, prefer the enqueued job instance or explicit `workflow_id` forms.

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

## Recurring Jobs

Use Temporal Schedules for cron-style recurring jobs:

```ruby
class DailyReportJob < ApplicationJob
  queue_as :reports

  schedule cron: "0 2 * * *", timezone: "America/New_York", overlap_policy: :skip

  def perform(account_id)
    DailyReport.generate_for(account_id)
  end
end
```

The class declaration is side-effect free. Register schedules explicitly during deployment or from a Rails task:

```ruby
DailyReportJob.create_temporal_schedule(args: [account.id], id: "daily-report:#{account.id}")

DailyReportJob.create_temporal_schedule(
  cron: "0 */6 * * *",
  timezone: "UTC",
  overlap_policy: :allow_all,
  args: [account.id],
  queue: :reports,
  id: "six-hour-report:#{account.id}"
)
```

Use explicit IDs when creating one schedule per account, tenant, or report. See the [Recurring Jobs Guide](docs/recurring_jobs.md) for overlap policies, schedule handles, and deployment notes.

## Retries

ActiveJob's `retry_on` and `discard_on` declarations are automatically translated to Temporal retry policies.

For a full mapping table and more examples, see the [Retry Policy Guide](docs/retry_policies.md).

> **Note:** Algorithmic wait strategies (`:exponentially_longer`, `:polynomially_longer`, and custom Procs) are not directly supported. Use static `wait:` values and Temporal's backoff configuration instead. See [Migration Guide - Known Limitations](docs/migration_guide.md#known-limitations) for details and examples.

### Basic Retry

```ruby
class SendInvoiceJob < ApplicationJob
  retry_on SomeTransientError, wait: 60.seconds, attempts: 5

  def perform(invoice_id)
    # Job logic that might raise SomeTransientError
  end
end
```

This maps to a Temporal RetryPolicy with:
- `initial_interval: 60` (seconds)
- `maximum_attempts: 5`
- `backoff_coefficient: 2.0` (from global config or default)

### Discard Non-Retryable Errors

```ruby
class SendInvoiceJob < ApplicationJob
  retry_on SomeTransientError, wait: 45.seconds, attempts: 3
  discard_on SomeFatalError

  def perform(invoice_id)
    # Job logic
  end
end
```

Errors matching `discard_on` are added to the `non_retryable_error_types` list in the RetryPolicy, so Temporal will not retry them.

### Multiple Retry Rules

```ruby
class MultiRetryJob < ApplicationJob
  retry_on StandardError, wait: 40.seconds, attempts: 2
  retry_on SpecificError, wait: 10.seconds, attempts: 6

  def perform
    # Job logic
  end
end
```

The gem maps multiple `retry_on` declarations into a single RetryPolicy. Because the policy is attached when the job is enqueued, the first handler in ActiveJob precedence order is used, which is usually the last declared rule.

### Exponential Backoff

Temporal automatically applies exponential backoff using the `default_retry_backoff` configuration (default: `2.0`). Retry delays double after each failed attempt:
- Retry delay 1: 60 seconds
- Retry delay 2: 120 seconds
- Retry delay 3: 240 seconds

`attempts:` counts total activity attempts, including the initial run. For example, `attempts: 5` allows four retry delays after the first failed attempt.

### Dead Letter Queue

Configure a dead letter queue when permanently failed jobs should remain inspectable for manual action:

```ruby
ActiveJob::Temporal.configure do |config|
  config.dead_letter_queue = "failed_jobs"
  config.dead_letter_after_attempts = 3
end
```

When activity retries are exhausted, the workflow starts an `ActiveJobTemporalDeadLetterWorkflow` on the configured queue and then fails normally. Run a worker polling that queue, for example `ACTIVEJOB_TEMPORAL_TASK_QUEUE=failed_jobs bundle exec temporal-worker`, so the DLQ workflow can initialize and answer queries. The DLQ workflow stores the original payload, failure class/message/fingerprint, job class, job ID, original queue, original workflow ID, attempt threshold, and failure time.

```ruby
entries = ActiveJob::Temporal.dead_letter_entries(queue: "failed_jobs", limit: 50)
entry = ActiveJob::Temporal.dead_letter_entry(SendInvoiceJob, job_id)
ActiveJob::Temporal.retry_dead_letter(SendInvoiceJob, job_id)
ActiveJob::Temporal.discard_dead_letter(SendInvoiceJob, job_id, reason: "handled manually")
```

Manual retry uses a deterministic retry workflow ID. Repeating the same retry request returns or marks the same retry workflow instead of starting another copy of the job.

`dead_letter_after_attempts` overrides the activity retry `maximum_attempts` for DLQ-enabled jobs so the configured DLQ threshold is authoritative. If you configure only `dead_letter_queue`, jobs move to the DLQ after their normal `retry_on` or default retry policy is exhausted.

DLQ metadata is plaintext Temporal workflow metadata, even when payload encryption is enabled. The original job execution payload remains encrypted when `encrypt_payload` is true, but DLQ inspection fields such as job class, job ID, queue, failure class, and failure message remain visible.

## Per-Job Timeout Configuration

You can configure activity timeouts on a per-job basis using the `temporal_options` class method. This overrides the global timeout defaults for specific jobs.

### Basic Timeout Override

```ruby
class QuickJob < ApplicationJob
  temporal_options start_to_close_timeout: 30.seconds

  def perform
    # Fast operation that should complete within 30 seconds
  end
end
```

### Long-Running Job with Heartbeat

```ruby
class DataProcessingJob < ApplicationJob
  temporal_options(
    start_to_close_timeout: 2.hours,
    heartbeat_timeout: 30.seconds
  )

  def perform(batch_id)
    records = Record.where(batch_id: batch_id)

    records.find_each do |record|
      process_record(record)

      # Send heartbeat to Temporal
      Temporalio::Activity::Context.current.heartbeat
    end
  end
end
```

### All Timeout Types

```ruby
class CriticalJob < ApplicationJob
  temporal_options(
    start_to_close_timeout: 10.minutes,      # Max execution time for a single attempt
    schedule_to_start_timeout: 1.minute,     # Max wait before activity starts
    schedule_to_close_timeout: 15.minutes,   # Total time including all retries
    heartbeat_timeout: 10.seconds            # Max interval between heartbeats
  )

  def perform
    # Critical operation with strict SLAs
  end
end
```

**Available Timeout Options:**
- `start_to_close_timeout` — Maximum execution time for a single activity attempt
- `heartbeat_timeout` — Maximum interval between heartbeats before the activity is considered failed
- `schedule_to_start_timeout` — Maximum wait time before the activity starts after scheduling
- `schedule_to_close_timeout` — Total time including all retries from schedule to completion

**Notes:**
- Timeout values can be specified as integers (seconds) or ActiveSupport::Duration objects (`2.hours`, `30.seconds`)
- At least one of `start_to_close_timeout` or `schedule_to_close_timeout` must be specified (either via `temporal_options` or global configuration)
- Per-job timeouts override global configuration defaults
- For long-running jobs, use `heartbeat_timeout` with regular `Temporalio::Activity::Context.current.heartbeat` calls to enable responsive cancellation

## Rate Limiting

Use `rate_limit` on a job class for per-job throughput and `config.global_rate_limit` for a process-wide rule that applies to every job payload. Rate limiting requires a backend object so applications can choose process-local, Redis, or another shared implementation.

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

The built-in `ActiveJob::Temporal::RateLimiters::Memory` limiter is useful for development, tests, and single-worker deployments. It is process-local, so use a shared backend for multi-process or multi-host workers.

A custom limiter can respond to `wait_time_for(rate_limits)` or `call(rate_limits)`. It receives an array of normalized hashes:

```ruby
[
  { "limit" => 1_000, "interval" => 60.0, "key" => "activejob-temporal:global" },
  { "limit" => 100, "interval" => 1.0, "key" => "external-api" }
]
```

Return `0` when the job can run now, or a finite positive number of seconds to wait. The check runs inside a Temporal activity, and the workflow uses a durable `Workflow.sleep` before rechecking, so limiter I/O stays out of deterministic workflow code and delayed jobs do not occupy the job activity slot while waiting.

Supported periods are `:second`, `:minute`, `:hour`, finite numeric seconds, or finite `ActiveSupport::Duration` values. Rate-limit keys stay plaintext in workflow payloads, including when payload encryption is enabled, so do not put secrets or customer data in custom keys.

## Cancellation

You can cancel in-flight jobs using the cancellation API:

```ruby
ActiveJob::Temporal.cancel(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
```

You can also terminate groups of running jobs by their ActiveJob search attributes:

```ruby
ActiveJob::Temporal.cancel_all(SendInvoiceJob)

ActiveJob::Temporal.cancel_where(ajQueue: "low_priority")
ActiveJob::Temporal.cancel_where(ajClass: "ReportJob", ajTenantId: 123)
# => { terminated: 45, failed: 2, errors: [...] }
```

**Parameters:**
- `job_class` — The job class constant (e.g., `SendInvoiceJob`)
- `job_id` — The ActiveJob job ID (UUID string)
- `cancel_where` filters — Exact matches for `ajClass`, `ajQueue`, `ajJobId`, `ajEnqueuedAt`, or `ajTenantId`

**Behavior:**
- Finds the workflow by `ajClass` and `ajJobId` search attributes
- Uses the discovered workflow ID, including custom IDs generated by `workflow_id_generator`
- Calls `handle.cancel` to request cancellation
- Returns `false` when the workflow already completed
- Raises `ActiveJob::Temporal::WorkflowNotFoundError` when no matching workflow exists
- Batch cancellation lists running workflows with Temporal visibility pagination
- Batch cancellation calls `handle.terminate` for each match and returns `{ terminated:, failed:, errors: }`

**Important:** For prompt cancellation, long-running jobs should periodically call `Temporalio::Activity::Context.current.heartbeat` to signal they are still alive. Temporal checks for cancellation requests during heartbeats.

Batch cancellation is forceful and only targets workflows that are currently `Running`.

### Example: Cancellable Job

```ruby
class LongRunningJob < ApplicationJob
  def perform
    100.times do |i|
      # Signal liveness to Temporal
      Temporalio::Activity::Context.current.heartbeat

      # Perform work
      process_chunk(i)
      sleep 1
    end
  end
end
```

Without heartbeating, the activity will run to completion even after cancellation is requested.

## Status Inspection

You can inspect job state without opening the Temporal UI:

```ruby
status = ActiveJob::Temporal.status(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
# => {
#      state: :running,
#      workflow_id: "ajwf:SendInvoiceJob:550e8400-e29b-41d4-a716-446655440000",
#      run_id: "abc123",
#      started_at: 2026-05-20 13:00:00 UTC,
#      closed_at: nil,
#      attempt: 2,
#      last_failure: "NetworkError: timeout"
#    }

ActiveJob::Temporal.running?(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
ActiveJob::Temporal.completed?(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
ActiveJob::Temporal.failed?(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
```

`status` returns `nil` when no workflow exists for the given job ID. Predicates return `false` for missing jobs.
`attempt` and `last_failure` are best-effort details from pending activities, so closed workflows may return `nil` for both.

## Signals and Queries

Signals mutate workflow-owned state. Queries read it without opening the Temporal UI:

```ruby
job_id = "550e8400-e29b-41d4-a716-446655440000"

ActiveJob::Temporal.signal(ImportJob, job_id, :pause, "maintenance")
ActiveJob::Temporal.query(ImportJob, job_id, :paused)
# => true

ActiveJob::Temporal.signal(ImportJob, job_id, :resume)
```

Built-in signals:

- `pause` marks the workflow paused at workflow checkpoints before the job activity starts and between workflow-owned waits
- `resume` clears the paused state

Built-in queries:

- `state` returns workflow-owned state such as phase, pause state, job class, job ID, queue name, and received signals
- `paused` returns a boolean
- `pause_reason` returns the latest pause reason when one was provided
- `phase` returns the workflow phase
- `signals` returns the latest received signal metadata by signal name

Jobs can declare custom workflow signal and query handlers:

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

  def perform(account_id)
    import_account(account_id)
  end
end

ActiveJob::Temporal.signal(ImportJob, job_id, :set_progress, 450, 1_000)
ActiveJob::Temporal.query(ImportJob, job_id, :progress)
# => { "completed" => 450, "total" => 1000, "percentage" => 45 }
```

Custom handlers run inside Temporal workflow code. Keep them deterministic: update only the provided state hash, avoid database calls, network calls, random values, process time, and other I/O. Built-in names (`pause`, `resume`, `state`, `paused`, `pause_reason`, `phase`, and `signals`) are reserved.

Pause/resume does not suspend Ruby code that is already executing inside `perform`, and it does not interrupt an active Temporal timer. ActiveJob execution runs in `AjRunnerActivity`, so a running activity needs cooperative behavior such as heartbeats, cancellation checks, or application-level checkpoint state.

## Observability

The gem attaches Temporal **Search Attributes** to every workflow, enabling powerful filtering and debugging in the Temporal UI.

### Search Attributes

| Attribute | Type | Description |
| --- | --- | --- |
| `ajClass` | Keyword | Fully qualified job class name (e.g., `"SendInvoiceJob"`). |
| `ajQueue` | Keyword | ActiveJob queue name (e.g., `"billing"`). Falls back to `"default"`. |
| `ajJobId` | Keyword | ActiveJob `job_id` (UUID) for correlation with application logs. |
| `ajEnqueuedAt` | Datetime | Timestamp when the adapter enqueued the workflow. |
| `ajTenantId` | Int (optional) | Tenant identifier extracted from job arguments when present. |
| `ajTags` | KeywordList (optional) | Custom tags configured with `set(tags:)`. |

### Registering Search Attributes

Search attributes must be registered once per Temporal cluster before they can be used. Use `tctl` (or the `temporal` CLI for Temporal Cloud):

```bash
tctl admin cluster add-search-attributes \
  --name ajClass --type Keyword \
  --name ajQueue --type Keyword \
  --name ajJobId --type Keyword \
  --name ajEnqueuedAt --type Datetime \
  --name ajTenantId --type Int \
  --name ajTags --type KeywordList
```

Add custom tags when enqueueing jobs:

```ruby
SendInvoiceJob.set(tags: [:urgent, :customer_123]).perform_later(invoice.id)
```

### Querying Jobs in Temporal UI

After registration, you can filter workflows in the Temporal UI using search queries:

**Example: Find all billing jobs for a specific tenant**
```
ajQueue = "billing" AND ajTenantId = 456
```

**Example: Find stale jobs enqueued before a certain date**
```
ajEnqueuedAt < "2025-01-01T00:00:00Z"
```

**Example: Find all instances of a specific job class**
```
ajClass = "SendInvoiceJob"
```

**Example: Find jobs with a custom tag**
```
ajTags = "urgent"
```

See the [Configuration Reference](docs/configuration_reference.md) for full search attributes documentation.

## Worker Deployment

Temporal workers poll task queues for workflows and activities to execute. You must run at least one worker process for each task queue your application uses.

### Quick Start

Run the worker from your Rails application directory. The `temporal-worker` executable auto-detects your Rails environment:

```bash
cd your-app
ACTIVEJOB_TEMPORAL_TARGET=localhost:7233 \
ACTIVEJOB_TEMPORAL_NAMESPACE=default \
ACTIVEJOB_TEMPORAL_TASK_QUEUE=default \
bundle exec temporal-worker
```

The worker automatically detects your Rails app (by checking for `config/application.rb`) and loads your environment, making job classes and initializers available.

Enable an optional health endpoint for load balancers or orchestrators:

```bash
bundle exec temporal-worker --health-check-port 8080
curl http://localhost:8080/health
```

For container probes or remote load balancers, bind the endpoint outside localhost:

```bash
bundle exec temporal-worker --health-check-bind 0.0.0.0 --health-check-port 8080
```

Expose Prometheus metrics for scraping:

```bash
bundle exec temporal-worker --metrics-bind 0.0.0.0 --metrics-port 9394
curl http://localhost:9394/metrics
```

Run a supervised local worker pool when you want multiple worker processes without an external process manager:

```bash
bundle exec temporal-worker --pool-size 3 --health-check-port 8080 --metrics-port 9394
```

The pool starts three child worker processes and restarts any child that exits unexpectedly. Health and metrics ports are assigned per worker from the base ports, so the example exposes health checks on `8080`, `8081`, and `8082`, and metrics on `9394`, `9395`, and `9396`. `SIGTERM` or `SIGINT` on the parent pool requests graceful shutdown for all children.

Workers reload TLS client certificates without restart when `ACTIVEJOB_TEMPORAL_TLS_CERT_WATCH=true` and TLS file paths are configured. You can also trigger a manual reload with `SIGHUP`:

```bash
kill -HUP <worker-pid>
```

For VM or bare-metal deployments, see the [systemd worker examples](examples/systemd/). They include a single worker service, a template for one worker per task queue, restart policy, file logging, and log rotation.

### Example Application

See [examples/basic_rails_app/](examples/basic_rails_app/) for a complete working Rails application demonstrating:

- Job enqueuing and execution (simple, scheduled, retryable, cancellable jobs)
- GlobalID serialization with seeded ActiveRecord subscriber records
- Per-job timeout configuration on long-running heartbeat jobs
- Full ActiveJob Temporal configuration
- Docker Compose setup for Rails, Temporal, Temporal UI, search attributes, and the worker
- Temporal UI screenshots captured from the running Docker Compose stack
- Worker setup, seed data, and example app tests
- How the auto-detection feature works

### Environment Variables

| Variable | Required | Description | Example |
| --- | --- | --- | --- |
| `ACTIVEJOB_TEMPORAL_TARGET` | Yes | Host and port of the Temporal frontend service. | `localhost:7233` or `temporal.example.com:7233` |
| `ACTIVEJOB_TEMPORAL_NAMESPACE` | Yes | Temporal namespace to poll for workflows. | `default` or `production` |
| `ACTIVEJOB_TEMPORAL_TASK_QUEUE` | No | Task queue the worker will poll for jobs. | `default` (if omitted) |
| `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES` | No | Maximum activity task poll capacity (defaults to `100`). | `50` or `200` |
| `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS` | No | Maximum workflow task poll capacity (defaults to `5`). | `20` or `50` |
| `ACTIVEJOB_TEMPORAL_WORKER_POOL_SIZE` | No | Number of child worker processes for `temporal-worker` to supervise. Defaults to `1`. | `3` |
| `ACTIVEJOB_TEMPORAL_METRICS_PROVIDER` | No | Metrics provider. Set to `prometheus` to collect built-in metrics. | `prometheus` |
| `ACTIVEJOB_TEMPORAL_METRICS_PORT` | No | Expose Prometheus metrics at `GET /metrics`. | `9394` |
| `ACTIVEJOB_TEMPORAL_METRICS_BIND` | No | Bind address for the metrics endpoint. Defaults to localhost. | `0.0.0.0` |
| `ACTIVEJOB_TEMPORAL_AUDIT_LOG` | No | Enable structured lifecycle audit events. | `true` |
| `ACTIVEJOB_TEMPORAL_DEAD_LETTER_QUEUE` | No | Task queue for parked dead letter workflows. | `failed_jobs` |
| `ACTIVEJOB_TEMPORAL_DEAD_LETTER_AFTER_ATTEMPTS` | No | Retry attempt limit before routing to the dead letter queue. | `3` |
| `ACTIVEJOB_TEMPORAL_PAYLOAD_SERIALIZER` | No | Serializer for new job execution payloads. | `json`, `message_pack`, or `marshal` |
| `ACTIVEJOB_TEMPORAL_ENCRYPT_PAYLOAD` | No | Encrypt job execution payloads before sending them to Temporal. | `true` |
| `ACTIVEJOB_TEMPORAL_ENCRYPTION_KEY` | Required when encryption is enabled | Base64-encoded 32-byte AES-256-GCM encryption key. | `SecureRandom.base64(32)` |
| `ACTIVEJOB_TEMPORAL_TLS_CERT_PATH` | Required for mTLS client certs | Client certificate file path. | `/etc/certs/client.pem` |
| `ACTIVEJOB_TEMPORAL_TLS_KEY_PATH` | Required with client cert path | Client private key file path. | `/etc/certs/client-key.pem` |
| `ACTIVEJOB_TEMPORAL_TLS_SERVER_ROOT_CA_CERT_PATH` | No | Root CA certificate file path for self-hosted TLS. | `/etc/certs/root-ca.pem` |
| `ACTIVEJOB_TEMPORAL_TLS_DOMAIN` | No | TLS SNI domain override. | `temporal.example.com` |
| `ACTIVEJOB_TEMPORAL_TLS_CERT_WATCH` | No | Watch TLS files and reload worker clients on change. | `true` |
| `ACTIVEJOB_TEMPORAL_TLS_RELOAD_SIGNAL` | No | Manual reload signal name. Defaults to `HUP`. | `USR1` |

### Performance Tuning

By default, the worker runs with:
- 100 activity task polls
- 5 workflow task polls

For different workloads, adjust via environment variables:

```bash
# High-throughput setup (production)
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=500 \
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=50 \
bundle exec temporal-worker

# Low-resource setup (development)
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=20 \
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=2 \
bundle exec temporal-worker
```

See [docs/performance_tuning.md](docs/performance_tuning.md) for workload-specific tuning and [docs/worker_setup.md](docs/worker_setup.md) for worker startup details.

## Documentation

Additional guides:

- [Documentation Index](docs/README.md)
- [Troubleshooting Guide](docs/troubleshooting.md)
- [Performance Tuning Guide](docs/performance_tuning.md)
- [Configuration Reference](docs/configuration_reference.md)
- [Metrics Guide](docs/metrics.md)
- [Retry Policy Guide](docs/retry_policies.md)
- [Worker Setup Guide](docs/worker_setup.md)
- [Migration Guide](docs/migration_guide.md)
- [Comparison Guide](docs/comparison.md)
- [Security](docs/security.md)

## Limitations (v0.1)

The following features are **not yet implemented** in v0.1 but are planned for future releases:

- **Updates** → Planned for v0.3
- **Child workflows** → Planned for v0.3
- **Rails generators** (for scaffolding jobs, initializers, etc.) → Planned for v1.0
- **ActiveRecord callback interception** (e.g., automatic transactional enqueue) → Deferred

**Other constraints:**
- **250KB payload size limit** (configurable via `max_payload_size_kb`). Jobs with larger plaintext or encrypted payloads will raise `ActiveJob::SerializationError`. Store large data externally (e.g., S3, database) and pass references instead.
- **Linear chains only:** `set(chain:)` supports sequential activities inside one workflow. Use `set(depends_on:)` for independently enqueued job gates. Child-workflow DAG orchestration is not yet supported.

## Migration from Sidekiq/Resque

Migrating from Sidekiq, Resque, or other queue adapters is straightforward:

1. **Add the gem** to your Gemfile and run `bundle install`
2. **Change the adapter** in `config/application.rb`:
   ```ruby
   config.active_job.queue_adapter = :temporal
   ```
3. **Configure Temporal** in an initializer (see [Configuration](#configuration))
4. **Register Search Attributes** with your Temporal cluster (one-time setup)
5. **Deploy workers** using `bin/temporal-worker` (see [Worker Deployment](#worker-deployment))
6. **Drain the old queue** (if applicable) to ensure no jobs are lost during the transition
7. **Monitor and verify** using Temporal UI and application logs

**For detailed migration instructions, see the [Migration Guide](docs/migration_guide.md)**, which includes:
- Dual-write migration strategy for zero-downtime cutover
- Side-by-side code comparisons (Sidekiq → ActiveJob)
- Common gotchas (payload size limits, idempotency, transaction safety)
- Testing checklist and rollback procedures

## Contributing

Contributions are welcome! To contribute:

1. Fork the repository
2. Create a feature branch (`git checkout -b my-feature`)
3. Make your changes and add tests
4. Install dependencies: `rvm 4.0.3 do bundle install`
5. Ensure unit tests pass: `rvm 4.0.3 do bundle exec rake spec:unit`
6. Ensure code is linted: `rvm 4.0.3 do bundle exec rubocop`
7. Ensure the gem builds: `rvm 4.0.3 do bundle exec rake build`
8. For changes near configured mutation subjects, run `rvm 4.0.3 do bundle exec rake mutation`
9. Commit your changes (`git commit -am 'Add new feature'`)
10. Push to the branch (`git push origin my-feature`)
11. Open a Pull Request

Please ensure:
- **Tests pass** (`rvm 4.0.3 do bundle exec rake spec:unit`) with >= 90% code coverage
- **Code is linted** (`rvm 4.0.3 do bundle exec rubocop`) with no offenses
- **Gem builds** (`rvm 4.0.3 do bundle exec rake build`) successfully
- **Mutation tests pass** (`rvm 4.0.3 do bundle exec rake mutation`) for the scoped Mutant baseline when touching covered code
- **Documentation is updated** (YARD comments, README, etc.) for new features

The scoped mutation task runs on Ruby 4. Mutant 0.16 may warn about an older parser dependency; keep using the Ruby 4 toolchain and treat parser failures on new Ruby syntax as a mutation tooling limitation.

For bug reports and feature requests, please [open an issue](https://github.com/schovi/activejob-temporal/issues).

## License

MIT. See [LICENSE](LICENSE).

## Versioning

This project follows [Semantic Versioning](https://semver.org/). See [CHANGELOG](CHANGELOG.md) for release history.

**Current version:** 0.1.0

---

**Questions or feedback?** Join the [Temporal community Slack](https://temporal.io/slack) or open an issue on GitHub.
