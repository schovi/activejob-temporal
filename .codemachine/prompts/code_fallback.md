# Code Refinement Task

The previous code submission did not pass verification. You must fix the following issues and resubmit your work.

---

## Original Task Description

Create `lib/activejob/temporal/payload.rb` with methods for serializing and deserializing ActiveJob arguments. Implement `Payload.from_job(job, scheduled_at: nil)` method that extracts job class name, job_id, queue_name, arguments (using ActiveJob::Arguments.serialize), scheduled_at timestamp (ISO8601 format if present), executions, and exception_executions. Return a hash suitable for JSON serialization. Implement `Payload.deserialize_args(payload)` method that converts the arguments array back to Ruby objects (using ActiveJob::Arguments.deserialize). Enforce 250KB payload size limit: raise `ActiveJob::SerializationError` if JSON-serialized payload exceeds 250KB (configurable via `config.max_payload_size_kb`, default 250). Write unit tests in `spec/unit/payload_spec.rb` covering: round-trip serialization (job → payload → args), GlobalID support (ActiveRecord models), payload size limit enforcement, error handling for non-serializable objects. Create JSON Schema for payload structure in `api/job_payload_schema.json` (Draft 07) defining required fields (job_class, job_id, queue_name, arguments) and optional fields (scheduled_at, executions, exception_executions).

---

## Issues Detected

*   **Coverage Gap:** Acceptance criteria require “SimpleCov reports 100% coverage for `lib/activejob/temporal/payload.rb`”, but the latest `bundle exec rake spec` run produces only ~96% overall coverage and reveals uncovered branches in `lib/activejob/temporal/payload.rb` (`iso8601_timestamp` fallback paths at lines 45-50 and the `valid_iso8601?` rescue at line 69). These code paths were never exercised, so the file is not fully covered.

---

## Best Approach to Fix

Augment `spec/unit/payload_spec.rb` with scenarios that exercise every branch of `iso8601_timestamp` and `valid_iso8601?`: (1) pass a value that lacks `iso8601` but implements `to_time` (e.g., `Date.today`) to ensure the `to_time` branch is executed; (2) pass an invalid ISO8601 string to trigger the `ArgumentError` path inside `valid_iso8601?`. Ensure these new examples assert the expected outcomes (successful conversion or raised error) so that SimpleCov reports 100% coverage for `lib/activejob/temporal/payload.rb`.
