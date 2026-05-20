# activejob-temporal

> Temporal-powered adapter for Rails ActiveJob.

[![Gem Version](https://badge.fury.io/rb/activejob-temporal.svg)](https://badge.fury.io/rb/activejob-temporal)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![CI](https://github.com/temporalio/activejob-temporal/actions/workflows/ci.yml/badge.svg)](https://github.com/temporalio/activejob-temporal/actions/workflows/ci.yml)
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
- ✅ **Conditional enqueueing:** Use `MyJob.perform_later_if(condition, args)` to skip jobs when no work is needed
- ✅ **Retry mapping:** ActiveJob `retry_on` declarations automatically map to Temporal retry policies with exponential backoff
- ✅ **Discard mapping:** `discard_on` maps to non-retryable errors, preventing wasted retry attempts
- ✅ **Per-job timeout configuration:** Configure activity timeouts per job using `temporal_options` class method
- ✅ **Job cancellation:** Cancel in-flight jobs via `ActiveJob::Temporal.cancel(JobClass, job_id)` API
- ✅ **Search attributes:** Filter and debug jobs in Temporal UI using job class, queue, job ID, tenant ID, custom tags, and enqueue timestamp
- ✅ **Transactional enqueue:** Jobs automatically defer enqueue until the current database transaction commits (via `enqueue_after_transaction_commit?`)
- ✅ **GlobalID support:** Seamless serialization of ActiveRecord models and other GlobalID-compatible objects
- ✅ **Configurable timeouts and retries:** Fine-tune activity timeouts, retry intervals, and backoff coefficients globally
- ✅ **Structured logging:** JSON logs for integration with observability infrastructure

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
- `temporalio` (>= 1.4.1) — the Temporal Ruby SDK

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
| `default_activity_timeout` | `ActiveSupport::Duration` | `15.minutes` | Default `start_to_close` timeout applied to activities that do not override it. Must be positive. |
| `default_retry_initial_interval` | `ActiveSupport::Duration` | `30.seconds` | Initial interval used by automatic retry logic before exponential backoff is applied. Must be positive. |
| `default_retry_backoff` | Float | `2.0` | Exponential factor used when calculating retry delays. |
| `default_retry_max_attempts` | Integer | `1` | Maximum retry attempts when a job does not specify its own `retry_on` rules. |
| `logger` | `Logger` | `Rails.logger` or `Logger.new($stdout)` | Destination for adapter log output. |
| `validation_level` | Symbol | `:strict` | Controls configuration validation: `:strict` raises, `:warn` logs warnings, `:none` skips validation. |
| `enable_tracing` | Boolean | `true` | Enables instrumentation hooks that emit OpenTelemetry spans. |
| `middleware_chain` | `ActiveJob::Temporal::Middleware::Chain` | Empty chain | Ordered middleware chain used by `config.add_middleware` to wrap job execution inside activities. |
| `max_payload_size_kb` | Integer | `250` | Maximum allowed size (in kilobytes) for serialized job payloads before raising `ActiveJob::SerializationError`. |

### Example Configuration

```ruby
# config/initializers/activejob_temporal.rb
ActiveJob::Temporal.configure do |config|
  config.target = "temporal.example.com:7233"
  config.namespace = "production"
  config.task_queue_prefix = "rails-"
  config.default_activity_timeout = 30.seconds
  config.default_retry_initial_interval = 10.seconds
  config.default_retry_backoff = 1.5
  config.default_retry_max_attempts = 5
  config.validation_level = :strict
  config.enable_tracing = false
  config.max_payload_size_kb = 512
end
```

Use `validation_level = :warn` during gradual configuration migrations when boot should continue but warnings should be visible. Use `validation_level = :none` only for test setups that intentionally build partial configuration.

For detailed configuration documentation, see [Configuration Reference](docs/configuration_reference.md).

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

**Note:** Recurring jobs via Temporal's Schedules API are planned for v0.2. For now, use a separate scheduling mechanism (like `whenever` gem or cron) to enqueue jobs periodically.

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

### Example Application

See [examples/basic_rails_app/](examples/basic_rails_app/) for a complete working Rails application demonstrating:

- Job enqueuing and execution (simple, scheduled, retryable, cancellable jobs)
- Full ActiveJob Temporal configuration
- Worker setup and testing
- How the auto-detection feature works

### Environment Variables

| Variable | Required | Description | Example |
| --- | --- | --- | --- |
| `ACTIVEJOB_TEMPORAL_TARGET` | Yes | Host and port of the Temporal frontend service. | `localhost:7233` or `temporal.example.com:7233` |
| `ACTIVEJOB_TEMPORAL_NAMESPACE` | Yes | Temporal namespace to poll for workflows. | `default` or `production` |
| `ACTIVEJOB_TEMPORAL_TASK_QUEUE` | No | Task queue the worker will poll for jobs. | `default` (if omitted) |
| `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES` | No | Maximum activity task poll capacity (defaults to `100`). | `50` or `200` |
| `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS` | No | Maximum workflow task poll capacity (defaults to `5`). | `20` or `50` |

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
- [Retry Policy Guide](docs/retry_policies.md)
- [Worker Setup Guide](docs/worker_setup.md)
- [Migration Guide](docs/migration_guide.md)
- [Comparison Guide](docs/comparison.md)
- [Security](docs/security.md)

## Limitations (v0.1)

The following features are **not yet implemented** in v0.1 but are planned for future releases:

- **Multi-activity workflows** (job chains/pipelines) → Planned for v0.3
- **Recurring jobs via Temporal Schedules API** → Planned for v0.2
- **Signals, Queries, and Updates** → Planned for v0.3
- **Child workflows** → Planned for v0.3
- **Rails generators** (for scaffolding jobs, initializers, etc.) → Planned for v1.0
- **ActiveRecord callback interception** (e.g., automatic transactional enqueue) → Deferred
- **Built-in metrics and alerting** → Planned for v0.2

**Other constraints:**
- **250KB payload size limit** (configurable via `max_payload_size_kb`). Jobs with larger payloads will raise `ActiveJob::SerializationError`. Store large data externally (e.g., S3, database) and pass references instead.
- **Single workflow + activity pattern:** Each job is executed as one workflow containing one activity. More complex orchestration patterns are not yet supported.

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
8. Commit your changes (`git commit -am 'Add new feature'`)
9. Push to the branch (`git push origin my-feature`)
10. Open a Pull Request

Please ensure:
- **Tests pass** (`rvm 4.0.3 do bundle exec rake spec:unit`) with >= 90% code coverage
- **Code is linted** (`rvm 4.0.3 do bundle exec rubocop`) with no offenses
- **Gem builds** (`rvm 4.0.3 do bundle exec rake build`) successfully
- **Documentation is updated** (YARD comments, README, etc.) for new features

For bug reports and feature requests, please [open an issue](https://github.com/temporalio/activejob-temporal/issues).

## License

MIT. See [LICENSE](LICENSE).

## Versioning

This project follows [Semantic Versioning](https://semver.org/). See [CHANGELOG](CHANGELOG.md) for release history.

**Current version:** 0.1.0

---

**Questions or feedback?** Join the [Temporal community Slack](https://temporal.io/slack) or open an issue on GitHub.
