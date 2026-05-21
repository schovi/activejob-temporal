# Documentation

Use this index to find the main guides for activejob-temporal.

## Operations

- [Worker Setup Guide](worker_setup.md) covers worker startup, deployment patterns, concurrency tuning, and expected logs.
- [Systemd Worker Examples](../examples/systemd/) provide VM and bare-metal service units, restart policy, file logging, and log rotation.
- [Basic Rails App](../examples/basic_rails_app/) provides a Docker Compose example with Rails, Temporal, Temporal UI, search attribute setup, a worker, seeded GlobalID records, and example tests.
- [Video Walkthrough Script](video_walkthrough_script.md) provides the recording plan and acceptance checklist for the quickstart walkthrough.
- [Performance Tuning Guide](performance_tuning.md) covers workload-specific concurrency, payload optimization, timeouts, database pooling, benchmarks, and monitoring.
- [Metrics Guide](metrics.md) covers Prometheus metrics, scrape endpoint setup, and the Grafana dashboard example.
- [Performance Benchmarks](benchmarks.md) describes the benchmark suite, covered operations, and baseline numbers.
- [Middleware Guide](middleware.md) explains how to wrap job execution with tracing, metrics, logging, and tenant context middleware.
- [Recurring Jobs Guide](recurring_jobs.md) explains cron schedules, registration, overlap policies, and schedule handles.
- [Troubleshooting Guide](troubleshooting.md) covers common enqueue, execution, retry, cancellation, payload, connection, and performance issues.
- [Security](security.md) covers dependency scanning, input validation, TLS notes, and payload handling.

## Configuration And Migration

- [Configuration Reference](configuration_reference.md) lists configuration options, environment variables, search attributes, and payload size settings.
- [Configuration Schema](config_schema.yaml) is the machine-readable configuration schema.
- [Ruby Baseline](ruby_baseline.md) documents the Ruby 4+ source of truth, local validation commands, and external tooling notes.
- [Migration Guide](migration_guide.md) covers migration from Sidekiq, Resque, Delayed Job, and other queue adapters.
- [Comparison Guide](comparison.md) helps choose between activejob-temporal, Sidekiq, GoodJob, Solid Queue, and Delayed Job.
- [Retry Policy Guide](retry_policies.md) explains how ActiveJob retry and discard declarations map to Temporal retry policies.

## Release And Publishing

- [Publishing](publishing.md) covers release and gem publishing steps.
- [Release Checklist](release_checklist.md) captures release validation status.

## Project Management

- [Issue Triage Handoff](issue_triage.md) records the project sorting model, blocked issue queue, and resume checklist.

## Architecture

- [Architecture Decision Records](adr/README.md) collects design decisions.
- [Diagrams](diagrams/) contains component, sequence, cancellation, and data model diagrams.
