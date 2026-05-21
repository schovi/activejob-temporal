# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

<!-- github_changelog_generator:start -->

**Implemented enhancements:**

- TASK.014 - Signals and Queries support [\#14](https://github.com/schovi/activejob-temporal/issues/14)
- TASK.017 - Worker pool management [\#17](https://github.com/schovi/activejob-temporal/issues/17)
- TASK.035 - Add rate limiting support [\#22](https://github.com/schovi/activejob-temporal/issues/22)
- TASK.022 - Add payload serialization options [\#19](https://github.com/schovi/activejob-temporal/issues/19)
- TASK.056 - Immediate Ruby 4+ migration task [\#56](https://github.com/schovi/activejob-temporal/issues/56)
- TASK.053 - Immediate Ruby 4+ migration follow-up [\#53](https://github.com/schovi/activejob-temporal/issues/53)
- TASK.052 - Reconfirm Ruby 4+ migration baseline [\#52](https://github.com/schovi/activejob-temporal/issues/52)
- TASK.051 - Enforce Ruby 4+ migration baseline [\#51](https://github.com/schovi/activejob-temporal/issues/51)
- TASK.050 - Migrate repository to Ruby 4+ [\#50](https://github.com/schovi/activejob-temporal/issues/50)
- TASK.043 - Add conditional enqueueing support [\#44](https://github.com/schovi/activejob-temporal/issues/44)
- TASK.039 - Add health check endpoint for workers [\#42](https://github.com/schovi/activejob-temporal/issues/42)
- TASK.023 - Add configuration validation levels [\#28](https://github.com/schovi/activejob-temporal/issues/28)
- TASK.021 - Extract WorkflowIdBuilder class [\#27](https://github.com/schovi/activejob-temporal/issues/27)
- TASK.019 - Replace method\_missing with explicit methods in Configuration [\#25](https://github.com/schovi/activejob-temporal/issues/25)
- TASK.042 - Add job tagging for search [\#24](https://github.com/schovi/activejob-temporal/issues/24)
- TASK.018 - Job prioritization via task queue routing [\#18](https://github.com/schovi/activejob-temporal/issues/18)
- TASK.016 - Built-in metrics integration [\#16](https://github.com/schovi/activejob-temporal/issues/16)
- TASK.015 - Recurring jobs via Temporal Schedules [\#15](https://github.com/schovi/activejob-temporal/issues/15)
- TASK.011 - Middleware system for cross-cutting concerns [\#11](https://github.com/schovi/activejob-temporal/issues/11)
- TASK.010 - Job status inspection API [\#10](https://github.com/schovi/activejob-temporal/issues/10)
- TASK.009 - Batch cancellation API [\#9](https://github.com/schovi/activejob-temporal/issues/9)
- TASK.008 - Add workflow ID customization hook [\#8](https://github.com/schovi/activejob-temporal/issues/8)
- TASK.007 - Extract configuration to separate file [\#7](https://github.com/schovi/activejob-temporal/issues/7)
- TASK.006 - Add payload size monitoring warnings [\#6](https://github.com/schovi/activejob-temporal/issues/6)

**Fixed bugs:**

- TASK.020 - Add RetryMapper fallback strategy for ActiveJob internals [\#26](https://github.com/schovi/activejob-temporal/issues/26)
- TASK.001 - Add explicit concurrent-ruby dependency [\#1](https://github.com/schovi/activejob-temporal/issues/1)

**Closed issues:**

- TASK.040 - Add Prometheus metrics exporter [\#43](https://github.com/schovi/activejob-temporal/issues/43)
- TASK.038 - Add systemd unit file example [\#41](https://github.com/schovi/activejob-temporal/issues/41)
- TASK.037 - Add Docker example with compose [\#40](https://github.com/schovi/activejob-temporal/issues/40)
- TASK.030 - Add performance benchmarks [\#36](https://github.com/schovi/activejob-temporal/issues/36)
- TASK.026 - Add gem comparison guide \(vs Sidekiq, GoodJob, etc\) [\#31](https://github.com/schovi/activejob-temporal/issues/31)
- TASK.025 - Add performance tuning guide [\#30](https://github.com/schovi/activejob-temporal/issues/30)
- TASK.024 - Add troubleshooting guide [\#29](https://github.com/schovi/activejob-temporal/issues/29)
- TASK.005 - Add retry policy documentation examples [\#5](https://github.com/schovi/activejob-temporal/issues/5)
- TASK.003 - Move SimpleCov configuration to standard location [\#3](https://github.com/schovi/activejob-temporal/issues/3)
- TASK.002 - Document algorithmic wait limitation in migration guide [\#2](https://github.com/schovi/activejob-temporal/issues/2)

<!-- github_changelog_generator:end -->

### Changed
- Reconfirm Ruby 4.0+ as the active repository baseline for local tooling, CI, dependency setup, and validation.
- Migrate the supported Ruby baseline and CI validation target to Ruby 4.0+.
- Pin the repository Ruby version for local development and document Ruby 4.0.3 validation commands.
- Support Temporal Ruby SDK 1.4.x for Ruby 4 compatibility, contract-tested against 1.4.0 and 1.4.1.
- Extract configuration state management into a dedicated `Configurable` concern.
- Extract deterministic workflow ID construction into `WorkflowIdBuilder`.
- Move SimpleCov configuration to `.simplecov` with coverage groups.
- Document algorithmic wait strategy limitations for retry migration.
- Serialize global activity timeout defaults into workflow payloads so workflows do not read mutable process configuration during replay.

### Fixed
- Declare `concurrent-ruby` as an explicit runtime dependency.

### Added
- Signal/query APIs via `ActiveJob::Temporal.signal` and `ActiveJob::Temporal.query`, with built-in pause/resume workflow state and deterministic custom job handlers.
- Global and per-job rate limiting with a pluggable limiter backend and durable workflow waits.
- Supervised worker pools via `ActiveJob::Temporal::WorkerPool` and `temporal-worker --pool-size`.
- Configurable payload serializer envelopes for MessagePack and Marshal while keeping JSON as the default wire format.
- Changelog generation configuration and `rake changelog:generate` release task.
- Structured audit logging for job enqueue, execution, failure, and cancellation lifecycle events.
- Optional AES-256-GCM payload encryption with key rotation support for job execution payloads.
- Codecov coverage badge and CI coverage uploads.
- Configurable `workflow_id_generator` hook for custom Temporal workflow IDs.
- Batch cancellation APIs via `ActiveJob::Temporal.cancel_all` and `ActiveJob::Temporal.cancel_where`.
- Job status inspection APIs via `ActiveJob::Temporal.status` and status predicates.
- Conditional enqueueing via `perform_later_if` for callable or class-method conditions.
- Optional worker health check endpoint via `temporal-worker --health-check-port PORT`.
- Priority-based task queue routing via `config.priority_task_queues`.
- Built-in Prometheus metrics and worker scrape endpoint via `temporal-worker --metrics-port PORT`.
- Configuration validation levels via `validation_level` for strict, warning-only, or skipped validation.
- Custom job search tags via `set(tags:)` and the `ajTags` Temporal search attribute.
- Recurring job declarations and explicit Temporal Schedule registration via `schedule` and `create_temporal_schedule`.
- Systemd worker deployment examples for VM and bare-metal hosts.
- Docker Compose example configuration for the basic Rails app.
- Structured payload size logs at 80%, 90%, and over-limit thresholds.
- Retry policy guide with ActiveJob-to-Temporal mapping examples.
- Per-job timeout configuration via `temporal_options` class method
  - Support for `start_to_close_timeout`, `heartbeat_timeout`, `schedule_to_start_timeout`, and `schedule_to_close_timeout`
  - Timeout values accept both integers (seconds) and `ActiveSupport::Duration` objects (e.g., `2.hours`, `30.seconds`)
  - Per-job timeouts override global configuration defaults
- Global timeout configuration options:
  - `default_heartbeat_timeout` for long-running activities with heartbeat monitoring
  - `default_schedule_to_start_timeout` to control max wait before activity starts
  - `default_schedule_to_close_timeout` for total time including all retries
- Comprehensive test coverage for timeout configuration (17 new unit tests, 3 integration tests)

## [0.1.0] - 2025-10-29

### Added
- ActiveJob adapter backed by Temporal workflows as a drop-in replacement for existing adapters
- Immediate job execution via `perform_later`
- Scheduled job execution with `set(wait:)` and `set(wait_until:)`
- Automatic retry policy mapping from `retry_on` declarations with exponential backoff
- Automatic discard policy handling from `discard_on` declarations
- Job cancellation API via `ActiveJob::Temporal.cancel(JobClass, job_id)`
- Search attributes for filtering and debugging jobs in Temporal UI (job class, queue, job ID, tenant ID, enqueue timestamp)
- Transactional enqueue support with automatic deferral until database transaction commits
- GlobalID serialization support for ActiveRecord models and other GlobalID-compatible objects
- Configurable activity timeouts and retry policies (global and per-job)
- Temporal worker executable (`bin/temporal-worker`) for running workers
- Structured JSON logging for observability integration
- Comprehensive documentation including README, API documentation (YARD), migration guide, and example Rails application

### Security
- Payload size limit of 250KB enforced to prevent denial-of-service attacks from oversized job payloads

\* *This Changelog was automatically generated by [github_changelog_generator](https://github.com/github-changelog-generator/github-changelog-generator)*
