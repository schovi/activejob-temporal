# Documentation

Use the root [README](../README.md) for install, first job, and a compact capability map. Use these guides when you need implementation detail.

## Start Here

- [Usage Patterns](usage_patterns.md): ActiveJob-facing APIs after setup, including scheduled jobs, conditional enqueueing, bulk enqueueing, chains, child workflows, dependencies, timeouts, rate limiting, cancellation, status, signals, queries, and updates.
- [Configuration Reference](configuration_reference.md): configuration options, environment variables, task queue routing, TLS, audit logging, payload serialization, encryption, search attributes, payload limits, and production tuning.
- [Worker Setup](worker_setup.md): worker startup, environment variables, health checks, metrics endpoints, worker pools, mTLS reloads, expected logs, and process shutdown.
- [Troubleshooting](troubleshooting.md): common enqueue, execution, retry, cancellation, payload, connection, and performance issues.

## Operations

- [Performance Tuning](performance_tuning.md): workload-specific concurrency, payload optimization, timeouts, database pooling, monitoring, and queue isolation.
- [Observability](observability.md): Rails notifications, tracing adapters, and optional Prometheus/OpenTelemetry/Datadog setup.
- [Metrics Guide](metrics.md): Prometheus metrics, scrape endpoint setup, useful queries, and the Grafana dashboard example.
- [Performance Benchmarks](benchmarks.md): benchmark suite coverage and baseline numbers.
- [Security](security.md): dependency scanning, input validation, TLS notes, payload handling, logging, and reporting.
- [Systemd Worker Examples](../examples/systemd/): VM and bare-metal service units, restart policy, file logging, and log rotation.
- [Basic Rails App](../examples/basic_rails_app/): Docker Compose example with Rails, Temporal, Temporal UI, search attributes, worker, seeded GlobalID records, and tests.

## Feature Guides

- [Recurring Jobs](recurring_jobs.md): cron schedules, registration, overlap policies, and schedule handles.
- [ActiveJob Lifecycle Guide](active_job_lifecycle.md): full ActiveJob execution under Temporal, including callbacks, middleware, rescue handlers, preserved job state, and retry ownership.
- [Retry Policy Guide](retry_policies.md): how ActiveJob `retry_on` and `discard_on` declarations map to Temporal retry policies.
- [Middleware](middleware.md): wrapping job execution with tracing, metrics, logging, tenant context, or cleanup middleware.
- [Nexus Integration](nexus.md): optional workflow-layer boundary for durable external service calls.
- [Comparison Guide](comparison.md): when to choose activejob-temporal instead of Sidekiq, GoodJob, Solid Queue, or Delayed Job.

## Release And Maintenance

- [Ruby Baseline](ruby_baseline.md): Ruby 4+ source of truth, local validation commands, CI coverage, and external tooling notes.
- [Release Checklist](release_checklist.md): release validation checklist.
- [Publishing](publishing.md): gem publishing prerequisites, procedure, rollback path, and command reference.
- [Configuration Schema](config_schema.yaml): machine-readable configuration schema.

## Project Notes

- [Issue Triage Handoff](issue_triage.md): project sorting model, blocked issue queue, and resume checklist.
- [Video Walkthrough Script](video_walkthrough_script.md): recording plan and acceptance checklist for the quickstart walkthrough.
- [Architecture Decision Records](adr/README.md): design decisions.
- [Diagrams](diagrams/): component, sequence, cancellation, and data model diagrams.
