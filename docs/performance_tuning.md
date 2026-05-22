# Performance Tuning Guide

Use this guide when Temporal task queues grow, job latency increases, or worker processes saturate CPU, memory, database connections, or downstream services.

For repeatable repository-level measurements, see [Performance Benchmarks](benchmarks.md).

Start with the defaults, measure, then change one setting at a time. The defaults are:

```bash
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=100
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=5
```

These settings are passed to the Temporal Ruby worker as activity and workflow task poll limits. They control how aggressively a worker polls for work, not a guaranteed number of simultaneously running jobs. The current gem exposes these poll limits and worker process count as its worker capacity knobs, so verify the actual effect with Temporal UI, worker logs, and host metrics.

The default `100` activity poll setting is an I/O-bound starting point. On MRI Ruby, CPU-bound jobs still contend on the GVL, so compression, rendering, parsing, encryption, and similar compute-heavy jobs should usually start near `Etc.nprocessors` activity polls per worker process, or lower when several worker processes share the same host.

## Tuning Loop

1. Record the current task queue backlog, job latency, worker CPU, worker memory, database pool usage, and downstream service latency.
2. Pick one bottleneck to address.
3. Change one setting or worker count.
4. Run enough representative work to see queue and resource behavior.
5. Keep the change only if latency improves without saturating another dependency.

Do not raise poll capacity just because a queue is busy. A bigger worker can make the system slower when jobs are CPU-bound, memory-heavy, database-heavy, or rate-limited by an external API.

## Worker Capacity

### Starting Points

| Scenario | Activity poll setting | Workflow task poll setting | Use when | Watch closely |
| --- | ---: | ---: | --- | --- |
| Local development or low-resource worker | `10` to `20` | `2` to `5` | Laptop, small VM, CI smoke test, or memory-constrained worker | Memory, CPU, local Temporal responsiveness |
| Balanced production default | `100` | `5` | Mixed I/O-heavy job durations with normal database and API calls | Activity task backlog, DB pool waits, worker memory |
| High-throughput short jobs | `300` to `500` | `25` to `50` | Jobs usually finish in under 1 second and spend time waiting on I/O | Downstream rate limits, log volume, Temporal frontend load |
| Long-running or database-heavy jobs | `10` to `50` | `5` to `10` | Jobs run for minutes, hold DB connections, load large records, or call slow services | DB connections, memory, retry storms |
| CPU-bound jobs | `2` to `8` per worker | `5` | Jobs compress, render, parse, encrypt, or otherwise burn CPU | CPU saturation and context switching |

For high availability, run at least two worker processes per important task queue. Prefer more worker processes over one very large worker when you need deploy safety, host-level redundancy, or cleaner resource limits.

### Environment Example

```bash
ACTIVEJOB_TEMPORAL_TARGET=temporal.example.com:7233 \
ACTIVEJOB_TEMPORAL_NAMESPACE=production \
ACTIVEJOB_TEMPORAL_TASK_QUEUE=mailers \
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=100 \
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=5 \
bundle exec temporal-worker
```

### When To Increase Activity Poll Capacity

Increase `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES` when all of these are true:

- The activity task queue backlog grows.
- Worker CPU and memory have headroom.
- Database connections and downstream services are not saturated.
- Jobs spend meaningful time waiting on I/O.

Reduce it when workers run out of memory, database pool waits increase, external APIs start rate-limiting, or CPU stays saturated.

### When To Increase Workflow Task Poll Capacity

Increase `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS` when workflow task latency grows or Temporal UI shows workflow task backlog while activity workers have headroom.

Workflow tasks are orchestration work. They schedule activities, process completions, schedule timers, and apply retry or discard decisions. They are usually lighter than activities, so the default `5` is enough for many apps.

## Payload Optimization

Temporal must store and move the job payload. Smaller payloads reduce enqueue time, worker memory, Temporal history size, log volume, and replay cost.

Prefer stable references:

```ruby
# Prefer this
ProcessInvoiceJob.perform_later(invoice.id)

# Also good when the model supports GlobalID
ProcessInvoiceJob.perform_later(invoice)

# Avoid this
ProcessInvoiceJob.perform_later(invoice.attributes)
```

The default payload limit is `250` KB. Jobs above the configured `max_payload_size_kb` raise `ActiveJob::SerializationError` before enqueue. Near the limit, the adapter emits structured payload logs:

- `payload_size_large` from 80% up to less than 90% of the limit
- `payload_size_near_limit` from 90% through the limit
- `payload_size_exceeded` above the limit

### Payload Benchmark

Measure payload cost in your application with representative jobs. This script avoids extra dependencies and works on Ruby 4:

```ruby
require "bundler/setup"
require "active_job"
require "activejob/temporal"
require "json"

ActiveJob::Temporal.config.logger = Logger.new(nil)

class PayloadBenchmarkJob < ActiveJob::Base
  def perform(*); end
end

def measure(label, argument)
  job = PayloadBenchmarkJob.new(argument)

  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  100.times { JSON.generate(ActiveJob::Temporal::Payload.from_job(job)) }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

  payload = JSON.generate(ActiveJob::Temporal::Payload.from_job(job))
  average_ms = ((elapsed / 100.0) * 1000).round(3)

  puts "#{label}: #{payload.bytesize} bytes, #{average_ms} ms/run"
end

measure("id", 123)
measure("200kb_string", "x" * (200 * 1024))
```

Example output measured in this repository on Ruby 4.0.3:

```text
id: 165 bytes, 0.001 ms/run
200kb_string: 204964 bytes, 0.068 ms/run
```

The timing is machine-specific. The important signal is size: a `200` KB string consumes most of the default `250` KB limit and triggers `payload_size_large` logs, while an ID stays tiny.

## Activity Timeouts

Set timeouts from actual job behavior, not from a generic default.

```ruby
class ExportReportJob < ApplicationJob
  temporal_options(
    start_to_close_timeout: 30.minutes,
    schedule_to_start_timeout: 2.minutes,
    schedule_to_close_timeout: 45.minutes,
    heartbeat_timeout: 30.seconds
  )

  def perform(report_id)
    rows_for(report_id).each_slice(100) do |rows|
      Temporalio::Activity::Context.current.heartbeat
      export_rows(rows)
    end
  end
end
```

Use:

- `start_to_close_timeout` for the maximum runtime of one activity attempt.
- `schedule_to_start_timeout` to fail when a task waits too long before a worker picks it up.
- `schedule_to_close_timeout` for the total wall-clock time from scheduling through completion, including retries.
- `heartbeat_timeout` for long jobs that heartbeat regularly.

Long-running jobs should heartbeat every 10 to 30 seconds or after each meaningful batch of work. Heartbeats let Temporal detect stuck workers and deliver cancellation promptly.

## Database Connection Pooling

Worker capacity only helps if the database can support the number of jobs that use it at the same time.

Estimate database demand per queue:

```text
worker_processes * simultaneous_db_using_jobs_per_process
```

If every job touches the database and one worker process is configured with 100 activity poll capacity, do not assume the default Rails pool of 5 connections is enough. Measure checked-out connections and pool waits, then increase the worker database pool, lower `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES`, split database-heavy jobs onto their own task queue, or add a pooler such as PgBouncer.

Keep web and worker pool sizing separate. Web requests and workers usually run in different processes and need separate database capacity planning.

## Monitoring

Watch these signals together:

- Temporal UI activity task queue backlog and schedule-to-start latency.
- Temporal UI workflow task queue backlog.
- Worker `worker_started` logs for task queue and poll settings.
- Prometheus metrics from `GET /metrics`, especially job duration, payload size, failed jobs, active workers, and active tasks.
- Payload logs: `payload_size_large`, `payload_size_near_limit`, and `payload_size_exceeded`.
- Job duration distribution by job class and queue.
- Worker CPU, memory, thread count, and restarts.
- Database pool wait time, checked-out connections, and query latency.
- Downstream API latency, error rate, and rate-limit responses.

The strongest signal is usually schedule-to-start latency. If it grows while workers have spare resources, add worker capacity. If it grows while a dependency is saturated, reduce poll capacity or isolate the expensive jobs.

See the [Metrics Guide](metrics.md) for the built-in Prometheus exporter and Grafana dashboard example.

## Queue Isolation

Use separate ActiveJob queues when workloads need different worker poll settings:

```ruby
class FastWebhookJob < ApplicationJob
  queue_as :webhooks
end

class LargeExportJob < ApplicationJob
  queue_as :exports

  temporal_options(
    start_to_close_timeout: 30.minutes,
    heartbeat_timeout: 30.seconds
  )
end
```

Then run workers with different settings:

```bash
ACTIVEJOB_TEMPORAL_TASK_QUEUE=webhooks \
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=500 \
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=50 \
bundle exec temporal-worker

ACTIVEJOB_TEMPORAL_TASK_QUEUE=exports \
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=20 \
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=5 \
bundle exec temporal-worker
```

This keeps slow exports from consuming capacity needed by short webhook jobs.

## Troubleshooting Decisions

- Activity backlog grows and workers are idle: increase activity poll capacity or add worker processes.
- Workflow backlog grows but activities are healthy: increase workflow task poll capacity.
- CPU is saturated: reduce activity poll capacity, split CPU-heavy jobs, or add hosts.
- Memory grows with worker load: lower activity poll capacity or reduce per-job object loading.
- Database pool waits grow: lower activity poll capacity or increase worker database pool capacity.
- Payload warnings appear: pass IDs or GlobalID records instead of large hashes, arrays, or file contents.
- Long jobs ignore cancellation: add `heartbeat_timeout` and heartbeat inside loops.

See [Worker Setup Guide](worker_setup.md) for worker startup details and [Troubleshooting Guide](troubleshooting.md) for failure-specific diagnostics.
