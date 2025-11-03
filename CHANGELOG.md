# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
