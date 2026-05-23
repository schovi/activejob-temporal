# activejob-temporal

> Temporal-powered adapter for Rails ActiveJob.

[![Gem Version](https://badge.fury.io/rb/activejob-temporal.svg)](https://badge.fury.io/rb/activejob-temporal)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![CI](https://github.com/schovi/activejob-temporal/actions/workflows/ci.yml/badge.svg)](https://github.com/schovi/activejob-temporal/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/schovi/activejob-temporal/branch/main/graph/badge.svg)](https://codecov.io/gh/schovi/activejob-temporal)

This gem is under active development. Expect breaking changes until v1.0.0.

## What It Does

`activejob-temporal` runs Rails ActiveJob work through [Temporal](https://temporal.io) workflows and activities. It is intended for jobs where durable execution, crash recovery, long-running retries, cancellation visibility, and Temporal UI history matter more than queue simplicity.

Use a traditional ActiveJob backend when the work is short, simple, and does not justify operating Temporal.

## Requirements

- Ruby >= 4.0
- Rails >= 7.2 through ActiveJob 8.x
- Temporal cluster, either self-hosted or [Temporal Cloud](https://temporal.io/cloud)

Temporal Ruby SDK 1.4.x compatibility is contract-tested against 1.4.0 and 1.4.1.

## Install

```ruby
gem "activejob-temporal"
```

```bash
bundle install
```

Then configure ActiveJob:

```ruby
# config/application.rb or config/environments/production.rb
config.active_job.queue_adapter = :temporal
```

## Quick Start

Create a Temporal initializer:

```ruby
# config/initializers/activejob_temporal.rb
ActiveJob::Temporal.configure do |config|
  config.target = ENV.fetch("ACTIVEJOB_TEMPORAL_TARGET", "127.0.0.1:7233")
  config.namespace = ENV.fetch("ACTIVEJOB_TEMPORAL_NAMESPACE", "default")
  config.task_queue_prefix = ENV.fetch("ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX", nil)

  config.default_activity_timeout = 15.minutes
  config.default_retry_initial_interval = 30.seconds
  config.default_retry_backoff = 2.0
  config.default_retry_max_attempts = 1
end
```

Register the built-in search attributes once per Temporal cluster:

```bash
tctl admin cluster add-search-attributes \
  --name ajClass --type Keyword \
  --name ajQueue --type Keyword \
  --name ajJobId --type Keyword \
  --name ajEnqueuedAt --type Datetime \
  --name ajTenantId --type Int \
  --name ajTags --type KeywordList
```

Temporal Cloud deployments may use the `temporal` CLI instead of `tctl`; keep the same attribute names and types.

Define and enqueue normal ActiveJob jobs:

```ruby
class SendInvoiceJob < ApplicationJob
  queue_as :billing

  retry_on SomeTransientError, wait: 60.seconds, attempts: 5
  discard_on SomeFatalError

  def perform(invoice_id)
    invoice = Invoice.find(invoice_id)
    InvoiceMailer.invoice_ready(invoice).deliver_now
  end
end

SendInvoiceJob.perform_later(invoice.id)
SendInvoiceJob.set(wait: 5.minutes).perform_later(invoice.id)
SendInvoiceJob.set(tags: [:urgent, :customer_123]).perform_later(invoice.id)
```

Start a worker for every task queue you use:

```bash
ACTIVEJOB_TEMPORAL_TARGET=localhost:7233 \
ACTIVEJOB_TEMPORAL_NAMESPACE=default \
ACTIVEJOB_TEMPORAL_TASK_QUEUE=billing \
bundle exec temporal-worker
```

Open Temporal UI and look for workflows named `ajwf:SendInvoiceJob:<job_id>`.

## Common Capabilities

| Need | API | Detailed guide |
| --- | --- | --- |
| Delay a single job | `MyJob.set(wait: 5.minutes).perform_later(...)` | [Usage Patterns](docs/usage_patterns.md#scheduled-jobs) |
| Register recurring cron work | `schedule cron: "0 2 * * *"` and `create_temporal_schedule` | [Recurring Jobs](docs/recurring_jobs.md) |
| Enqueue only when work exists | `perform_later_if(condition, *args)` | [Usage Patterns](docs/usage_patterns.md#conditional-enqueueing) |
| Enqueue many prepared jobs | `ActiveJob::Temporal.enqueue_batch(jobs)` | [Usage Patterns](docs/usage_patterns.md#bulk-enqueueing) |
| Run sequential jobs in one workflow | `set(chain: [NextJob])` | [Usage Patterns](docs/usage_patterns.md#job-chaining) |
| Start child ActiveJob workflows | `set(child_workflows: [ChildJob])` | [Usage Patterns](docs/usage_patterns.md#child-workflows) |
| Wait for separately enqueued jobs | `set(depends_on: parent_job)` | [Usage Patterns](docs/usage_patterns.md#job-dependencies) |
| Map ActiveJob retries to Temporal | `retry_on`, `discard_on` | [Retry Policy Guide](docs/retry_policies.md) |
| Park exhausted failures | `config.dead_letter_queue = "failed_jobs"` | [Configuration Reference](docs/configuration_reference.md#dead-letter-queue) |
| Tune activity timeouts | `temporal_options start_to_close_timeout: ...` | [Usage Patterns](docs/usage_patterns.md#per-job-timeouts) |
| Add throughput limits | `rate_limit 100, per: :second` | [Configuration Reference](docs/configuration_reference.md#rate-limit-configuration) |
| Cancel or inspect jobs | `cancel`, `cancel_all`, `status`, `running?` | [Usage Patterns](docs/usage_patterns.md#cancellation-and-status) |
| Pause, resume, query, or update workflow state | `signal`, `query`, `update` | [Usage Patterns](docs/usage_patterns.md#signals-queries-and-updates) |
| Add runtime middleware | `config.add_middleware MiddlewareClass` | [Middleware](docs/middleware.md) |
| Expose Prometheus metrics | `metrics_provider = :prometheus` | [Metrics Guide](docs/metrics.md) |
| Encrypt job payloads | `encrypt_payload = true` | [Configuration Reference](docs/configuration_reference.md#payload-encryption) |
| Store large payloads externally | `payload_storage_adapter = MyPayloadStorage.new` | [Configuration Reference](docs/configuration_reference.md#payload-size-limits) |

Baseline behavior also includes transaction-aware enqueueing through ActiveJob, GlobalID-compatible argument serialization, structured JSON logs, searchable `set(tags:)` metadata, and JSON payloads with opt-in MessagePack or Marshal envelopes.

## Configuration

The full configuration surface lives in [Configuration Reference](docs/configuration_reference.md). The machine-readable schema is [docs/config_schema.yaml](docs/config_schema.yaml).

The most common settings are:

```ruby
ActiveJob::Temporal.configure do |config|
  config.target = "temporal.example.com:7233"
  config.namespace = "production"
  config.task_queue_prefix = "rails-"
  config.priority_task_queues = { 10 => "high_priority", 90 => "low_priority" }
  config.default_activity_timeout = 30.seconds
  config.default_retry_initial_interval = 10.seconds
  config.default_retry_backoff = 1.5
  config.default_retry_max_attempts = 5
end
```

Workers can also read environment variables such as `ACTIVEJOB_TEMPORAL_TARGET`, `ACTIVEJOB_TEMPORAL_NAMESPACE`, `ACTIVEJOB_TEMPORAL_TASK_QUEUE`, `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES`, `ACTIVEJOB_TEMPORAL_METRICS_PORT`, and TLS certificate settings. See [Worker Setup](docs/worker_setup.md) for the worker-focused list.

## Current Constraints

- Chains are linear. Use child workflows for parent-owned fan-out and dependencies for independently enqueued job gates.
- Algorithmic retry waits such as `:exponentially_longer`, `:polynomially_longer`, and Proc waits fall back to numeric Temporal retry policy settings.
- Cancellation inside running Ruby job code is cooperative. Long-running activities need heartbeats or explicit cancellation checks.
- Nexus remains an explicit workflow-layer integration. Ordinary ActiveJob execution stays activity-based. See [Nexus Integration](docs/nexus.md).

## Documentation

Start with [docs/README.md](docs/README.md) for the complete documentation map.

High-use guides:

- [Usage Patterns](docs/usage_patterns.md)
- [Configuration Reference](docs/configuration_reference.md)
- [Worker Setup](docs/worker_setup.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Performance Tuning](docs/performance_tuning.md)
- [Comparison Guide](docs/comparison.md)
- [Security](docs/security.md)

See [examples/basic_rails_app](examples/basic_rails_app/) for a Docker Compose Rails app with Temporal, Temporal UI, search attribute setup, workers, seeded GlobalID records, and tests.

## Contributing

Install dependencies and run the focused local checks:

```bash
rvm 4.0.3 do bundle install
rvm 4.0.3 do bundle exec rake spec:unit
rvm 4.0.3 do bundle exec rubocop
rvm 4.0.3 do bundle exec rake build
```

For changes near configured mutation subjects, also run:

```bash
rvm 4.0.3 do bundle exec rake mutation
```

Keep docs updated when behavior changes. The scoped mutation task runs on Ruby 4. Mutant 0.16 may warn about an older parser dependency; keep using the Ruby 4 toolchain and treat parser failures on new Ruby syntax as a mutation tooling limitation.

Bug reports and feature requests belong in [GitHub issues](https://github.com/schovi/activejob-temporal/issues).

## License

MIT. See [LICENSE](LICENSE).

## Versioning

This project follows [Semantic Versioning](https://semver.org/). See [CHANGELOG](CHANGELOG.md) for release history.

Current version: 0.1.0
