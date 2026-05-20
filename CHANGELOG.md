# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Migrate the supported Ruby baseline and CI validation target to Ruby 4.0+.
- Pin the repository Ruby version for local development and document Ruby 4.0.3 validation commands.
- Require Temporal Ruby SDK 1.4.1+ for Ruby 4 compatibility.
- Extract configuration state management into a dedicated `Configurable` concern.
- Extract deterministic workflow ID construction into `WorkflowIdBuilder`.
- Move SimpleCov configuration to `.simplecov` with coverage groups.
- Document algorithmic wait strategy limitations for retry migration.
- Serialize global activity timeout defaults into workflow payloads so workflows do not read mutable process configuration during replay.

### Fixed
- Declare `concurrent-ruby` as an explicit runtime dependency.

### Added
- Codecov coverage badge and CI coverage uploads.
- Configurable `workflow_id_generator` hook for custom Temporal workflow IDs.
- Batch cancellation APIs via `ActiveJob::Temporal.cancel_all` and `ActiveJob::Temporal.cancel_where`.
- Job status inspection APIs via `ActiveJob::Temporal.status` and status predicates.
- Conditional enqueueing via `perform_later_if` for callable or class-method conditions.
- Optional worker health check endpoint via `temporal-worker --health-check-port PORT`.
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
