# Job Queue Comparison

Use this guide when deciding whether activejob-temporal is the right ActiveJob backend for a Rails application.

No backend is best for every team. Sidekiq, GoodJob, Solid Queue, Delayed Job, and activejob-temporal optimize for different infrastructure, failure, and workflow tradeoffs.

## Short Version

Choose activejob-temporal when job correctness depends on durable execution, retries across worker crashes, long-running work, cancellation visibility, or Temporal UI observability.

Choose a traditional queue when the work is short, operational simplicity matters more than workflow durability, or your team does not want to run Temporal.

## Feature Matrix

| Capability | Sidekiq | GoodJob | Solid Queue | Delayed Job | activejob-temporal |
| --- | --- | --- | --- | --- | --- |
| ActiveJob adapter | Yes | Yes | Yes | Yes | Yes |
| Primary backend | Redis | PostgreSQL | SQL database | Database backend | Temporal service |
| Extra service required beyond Rails database | Redis | No | No | No | Temporal cluster or Temporal Cloud |
| Durable progress through worker crash | Limited in OSS; Sidekiq Pro `super_fetch` improves crash recovery | Queue retry after failure | Queue retry after failure | Queue retry after failure | Temporal workflow event history resumes progress |
| Long-running jobs | Possible with tuning | Possible with database/pool tuning | Possible with database/pool tuning | Possible with `max_run_time` tuning | Strong fit when jobs heartbeat and timeouts are set |
| Built-in workflow history | Limited to queue/error records | Dashboard/job records | Queue records | Job table records | Temporal event history |
| Built-in operational UI | Web UI | Web Dashboard | Mission Control Jobs for Rails | Third-party or custom | Temporal UI |
| Scheduled jobs | Yes | Yes | Yes | Yes | ActiveJob delayed jobs; recurring Temporal schedules are planned |
| Batches/chains/workflow composition | Sidekiq Pro/Enterprise for batches | Batches supported | Not the main model | Not the main model | Planned beyond the current single workflow plus activity pattern |
| Cancellation API in this gem | Backend-specific | Backend-specific | Backend-specific | Backend-specific | `ActiveJob::Temporal.cancel`, `cancel_all`, and `cancel_where` |
| Search/filter by job metadata | Backend-specific | Dashboard/database query | Backend-specific | Database query | Temporal Search Attributes |
| Operational learning curve | Low to medium if Redis is familiar | Low if PostgreSQL is familiar | Low for Rails 8 apps | Low | Medium to high unless Temporal is already in use |

## When To Choose Sidekiq

Sidekiq is a good fit when:

- You already run Redis as durable queue infrastructure.
- Jobs are mostly short-lived and idempotent.
- Throughput and ecosystem maturity are primary requirements.
- You want the Sidekiq Web UI and optional Pro/Enterprise features.

Watch for:

- Redis must be operated as queue storage, not as disposable cache storage.
- Open-source Sidekiq does not provide the same worker-crash recovery guarantees as Sidekiq Pro `super_fetch`.
- Complex workflows need application-level state machines or paid Sidekiq features.
- Long-running jobs need careful timeout, shutdown, and idempotency handling.

Reference: Sidekiq stores job and operational data in Redis, recommends dedicated Redis configuration for queue use, and documents `super_fetch` as a Pro reliability feature.

## When To Choose GoodJob

GoodJob is a good fit when:

- Your app already depends on PostgreSQL and you want to avoid Redis.
- You want a Rails-native ActiveJob backend with a dashboard.
- Jobs are conventional background work: mailers, webhooks, imports, cleanup, and scheduled tasks.
- You want to keep operations inside familiar Rails and PostgreSQL tooling.

Watch for:

- Job throughput and latency share capacity with PostgreSQL.
- Database connection pool sizing matters for worker-heavy deployments.
- Multi-step workflows still need application-level orchestration.

Reference: GoodJob describes itself as a multithreaded, Postgres-backed ActiveJob backend with queues, delays, retries, cron-like scheduled jobs, batches, concurrency controls, and a dashboard.

## When To Choose Solid Queue

Solid Queue is a good fit when:

- You are on Rails 8 or are standardizing on Rails defaults.
- You want database-backed ActiveJob without Redis.
- You prefer a first-party Rails queue that uses standard app infrastructure.
- Your jobs are ordinary background tasks rather than durable workflows.

Watch for:

- Queue load shares database capacity with the rest of the application unless you isolate it.
- It is a queue backend, not a workflow engine.
- Long-running or multi-step business processes need separate design for progress, recovery, and observability.

Reference: Rails documents Solid Queue as the Rails 8 default database-backed ActiveJob queue that avoids extra dependencies such as Redis.

## When To Choose Delayed Job

Delayed Job is a good fit when:

- You need a mature database-backed queue.
- Throughput requirements are modest or predictable.
- You value simple deployment and database visibility.
- You are maintaining an older Rails app already using Delayed Job.

Watch for:

- High queue volume can add load to the application database.
- Very long jobs require `max_run_time` tuning and idempotency discipline.
- Operational UI and workflow visibility are limited compared with newer tools.

Reference: Delayed Job documents database-backed asynchronous jobs, ActiveJob adapter usage, named queues, priorities, scheduled jobs, worker processes, and `Worker.max_run_time`.

## When To Choose activejob-temporal

activejob-temporal is a good fit when:

- A job should continue reliably across worker crashes, process deploys, network failures, or Temporal worker restarts.
- You need Temporal UI, event history, Search Attributes, cancellation, and status inspection for ActiveJob work.
- Jobs may run long enough to need heartbeats and explicit timeouts.
- You already operate Temporal or are willing to adopt Temporal Cloud or a self-hosted Temporal service.
- You want a migration path from ActiveJob queues to durable execution while keeping the ActiveJob API.

Watch for:

- You must operate Temporal or use Temporal Cloud.
- Search Attributes must be registered before workflows can be filtered.
- Current v0.1 jobs use a single workflow plus one activity. Multi-activity workflows, job chains, child workflows, signals, queries, and recurring Temporal schedules are planned but not current behavior.
- Temporal workflow determinism limits what code can run inside workflow definitions. This gem keeps user job code in activities, but upgrades still need care when workflow histories exist.
- Payload size matters. The default maximum is `250` KB, so pass IDs or GlobalID records instead of large objects.

## Decision Checklist

Use activejob-temporal when most answers are yes:

- Would losing progress after a crash create customer-visible damage or manual recovery work?
- Do jobs run for minutes or longer?
- Do operators need to inspect execution history, attempts, cancellation, and status in a durable UI?
- Are retries, timeouts, and cancellation part of the product behavior?
- Is the team comfortable operating Temporal?

Use Sidekiq, GoodJob, Solid Queue, or Delayed Job when most answers are yes:

- Are jobs short and naturally idempotent?
- Is queue throughput more important than durable workflow history?
- Is the current Redis or database queue already reliable enough for the workload?
- Would introducing Temporal be more operational weight than the job requires?

## Migration Notes

Migrating from a queue to activejob-temporal is not only a gem swap. Plan for:

- Temporal cluster or Temporal Cloud access.
- Search Attribute registration.
- Worker deployment for each task queue.
- Payload size checks.
- Idempotency review.
- Heartbeats for long-running jobs.
- A rollback path while old queues drain.

See the [Migration Guide](migration_guide.md), [Worker Setup Guide](worker_setup.md), [Performance Tuning Guide](performance_tuning.md), and [Troubleshooting Guide](troubleshooting.md) for implementation details.

## References

- [Sidekiq Redis documentation](https://github.com/sidekiq/sidekiq/wiki/Using-Redis)
- [Sidekiq reliability documentation](https://github.com/sidekiq/sidekiq/wiki/Reliability)
- [GoodJob README](https://github.com/bensheldon/good_job)
- [Rails Active Job Basics](https://guides.rubyonrails.org/active_job_basics.html)
- [Delayed Job README](https://github.com/collectiveidea/delayed_job)
- [Temporal durable execution overview](https://docs.temporal.io/temporal)
