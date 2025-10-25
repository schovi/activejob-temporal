# Project Plan: activejob-temporal Gem - Iteration 4

---

<!-- anchor: iteration-4-plan -->
### Iteration 4: Worker Bootstrap & Integration Testing

*   **Iteration ID:** `I4`
*   **Goal:** Implement the Temporal worker bootstrap script, write comprehensive integration tests with a real Temporal test server, and validate end-to-end functionality (enqueue → workflow → activity → job execution).
*   **Prerequisites:** `I1` (Foundation), `I2` (Workflow/Activity), `I3` (Adapter/Cancellation)
*   **Tasks:**

<!-- anchor: task-i4-t1 -->
*   **Task 4.1: Implement Worker Bootstrap Script**
    *   **Task ID:** `I4.T1`
    *   **Description:** Create `bin/temporal-worker` executable script that bootstraps a Temporal worker process. The script must: (1) Require the gem's entrypoint (`require 'activejob-temporal'`). (2) Require Rails environment if RAILS_ROOT env var is set (for loading job classes): `require File.expand_path('../config/environment', ENV['RAILS_ROOT'])` (or similar). (3) Read worker configuration from environment variables: `TEMPORAL_TARGET`, `TEMPORAL_NAMESPACE`, `AJ_TEMPORAL_WORKER_QUEUE` (task queue to poll), `AJ_TEMPORAL_MAX_ACT` (max concurrent activities, default 100). (4) Get Temporal client using `ActiveJob::Temporal.client` (configured via env vars or config file). (5) Create Temporal worker: `worker = Temporalio::Worker.new(client: client, task_queue: ENV.fetch('AJ_TEMPORAL_WORKER_QUEUE', 'default'), workflows: [ActiveJob::Temporal::Workflows::AjWorkflow], activities: [ActiveJob::Temporal::Activities::AjRunnerActivity], shutdown_signals: %w[SIGINT SIGTERM], max_concurrent_activity_task_executions: ENV.fetch('AJ_TEMPORAL_MAX_ACT', 100).to_i)`. (6) Start worker with `worker.run` (blocks until shutdown signal). (7) Log worker startup and shutdown events using `Logger.log_event`. (8) Handle graceful shutdown: on SIGTERM/SIGINT, worker finishes in-flight activities before exiting. Make the script executable (`chmod +x bin/temporal-worker`). Write basic manual test instructions in `docs/worker_setup.md` explaining how to run the worker locally against a Temporal test server.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 3.9 (Deployment View - Worker Bootstrap), temporalio-sdk Ruby worker documentation, environment variable best practices
    *   **Input Files:**
        - `lib/activejob-temporal.rb`
        - `lib/activejob/temporal/workflows/aj_workflow.rb`
        - `lib/activejob/temporal/activities/aj_runner_activity.rb`
        - `lib/activejob/temporal/client.rb`
        - `lib/activejob/temporal/logger.rb`
    *   **Target Files:**
        - `bin/temporal-worker`
        - `docs/worker_setup.md` (worker manual test instructions)
    *   **Deliverables:** Executable worker script, worker setup documentation, working graceful shutdown
    *   **Acceptance Criteria:**
        - `bin/temporal-worker` file exists and is executable (`chmod +x`)
        - Script starts with shebang: `#!/usr/bin/env ruby`
        - Script requires gem entrypoint and (optionally) Rails environment
        - Worker is created with correct parameters: `task_queue`, `workflows`, `activities`, `shutdown_signals`, `max_concurrent_activity_task_executions`
        - Worker starts and blocks on `worker.run`
        - Log event "worker_started" is written with task_queue, max_concurrency
        - On SIGTERM/SIGINT, worker gracefully shuts down (logs "worker_shutdown" event)
        - `docs/worker_setup.md` includes: prerequisites (Temporal test server running), how to run worker (`bin/temporal-worker`), environment variables needed, expected log output
        - Manual test: Running `TEMPORAL_TARGET=localhost:7233 AJ_TEMPORAL_WORKER_QUEUE=default bin/temporal-worker` starts worker without errors (can be tested manually or in integration tests)
    *   **Dependencies:** I1.T4 (Client), I1.T8 (Logger), I2.T2 (AjWorkflow), I2.T3 (AjRunnerActivity)
    *   **Parallelizable:** No (worker needs all components from I1, I2, I3 to be complete)

<!-- anchor: task-i4-t2 -->
*   **Task 4.2: Set Up Temporal Test Server Helper**
    *   **Task ID:** `I4.T2`
    *   **Description:** Create `spec/support/temporal_test_server.rb` with a helper to start and stop a Temporal test server for integration tests. The Temporal Ruby SDK may include a test server (check SDK documentation). If available, wrap it in RSpec `before(:suite)` and `after(:suite)` hooks to start server once before all integration tests and stop after. If SDK doesn't include test server, document manual setup: run `temporal server start-dev` in background before tests, or use Docker Compose. Provide a method `TemporalTestHelper.client` that returns a client connected to the test server. Ensure test server uses a test namespace (e.g., "test"). Write a simple smoke test in `spec/integration/temporal_connection_spec.rb` that verifies connection to test server (e.g., list workflows, should return empty list initially). This ensures test infrastructure is working before writing real integration tests.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** temporalio-sdk Ruby testing documentation, Temporal test server documentation, RSpec setup patterns
    *   **Input Files:**
        - `spec/spec_helper.rb`
    *   **Target Files:**
        - `spec/support/temporal_test_server.rb`
        - `spec/integration/temporal_connection_spec.rb` (smoke test)
        - `spec/spec_helper.rb` (updated to require temporal_test_server helper)
    *   **Deliverables:** Working Temporal test server setup, passing smoke test for connection
    *   **Acceptance Criteria:**
        - `spec/support/temporal_test_server.rb` exists with `TemporalTestHelper` module
        - Helper starts Temporal test server (or documents manual setup)
        - Helper provides `TemporalTestHelper.client` method returning connected client
        - Test server uses "test" namespace
        - `spec/spec_helper.rb` requires temporal_test_server helper
        - Smoke test in `spec/integration/temporal_connection_spec.rb` connects to test server and lists workflows (empty list expected)
        - `rake spec` passes for temporal_connection_spec.rb
        - Manual verification: Running `rake spec:integration` starts test server and runs smoke test
    *   **Dependencies:** I1.T4 (Client module, needed for connection logic)
    *   **Parallelizable:** Yes (can run in parallel with I4.T1 if I1 is complete)

<!-- anchor: task-i4-t3 -->
*   **Task 4.3: Write Integration Test - Immediate Job Execution**
    *   **Task ID:** `I4.T3`
    *   **Description:** Write integration test in `spec/integration/enqueue_spec.rb` that tests end-to-end immediate job execution (no scheduling). Test flow: (1) Define a simple test job (e.g., `class TestJob < ApplicationJob; def perform(arg); $test_result = arg; end; end`). (2) Configure ActiveJob to use TemporalAdapter (in test setup). (3) Enqueue job: `TestJob.perform_later(42)`. (4) Start a Temporal worker in a background thread (or subprocess) polling the "default" task queue. (5) Wait for job to execute (poll `$test_result` or use a more robust mechanism like condition variables or test helper). (6) Assert `$test_result == 42`. (7) Verify workflow completed in Temporal (query workflow history using test client). (8) Clean up: stop worker, reset state. Use Temporal test server from I4.T2. This is a full end-to-end test proving enqueue → workflow → activity → job execution works.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** RSpec integration test patterns, Temporal test server helper from I4.T2, adapter from I3.T1, workflow/activity from I2.T2/I2.T3, worker bootstrap logic from I4.T1
    *   **Input Files:**
        - `spec/support/temporal_test_server.rb`
        - `lib/activejob/temporal/adapter.rb`
        - `lib/activejob/temporal/workflows/aj_workflow.rb`
        - `lib/activejob/temporal/activities/aj_runner_activity.rb`
        - `spec/fixtures/sample_jobs.rb` (update with TestJob)
    *   **Target Files:**
        - `spec/integration/enqueue_spec.rb`
        - `spec/fixtures/sample_jobs.rb` (updated with TestJob)
    *   **Deliverables:** Passing integration test for immediate job execution
    *   **Acceptance Criteria:**
        - Integration test defines a simple ActiveJob job (TestJob)
        - Test configures ActiveJob adapter to TemporalAdapter
        - Test enqueues job: `TestJob.perform_later(42)`
        - Test starts a worker in background (thread or subprocess) polling task queue
        - Test waits for job execution (max 10 seconds timeout)
        - Test asserts job executed with correct argument (`$test_result == 42` or similar)
        - Test queries Temporal for workflow completion (using test client)
        - Test cleans up: stops worker, resets state
        - `rake spec:integration` (or `rake spec`) passes for enqueue_spec.rb (immediate execution test)
        - Test is isolated (can run multiple times without interference)
    *   **Dependencies:** I3.T1 (Adapter), I2.T2 (AjWorkflow), I2.T3 (AjRunnerActivity), I4.T2 (Temporal test server)
    *   **Parallelizable:** No (integration test, depends on I3 and I4.T2)

<!-- anchor: task-i4-t4 -->
*   **Task 4.4: Write Integration Test - Scheduled Job Execution**
    *   **Task ID:** `I4.T4`
    *   **Description:** Write integration test in `spec/integration/scheduled_jobs_spec.rb` that tests scheduled job execution using `set(wait:)`. Test flow: (1) Define test job. (2) Enqueue job with delay: `TestJob.set(wait: 5.seconds).perform_later(42)`. (3) Start worker. (4) Assert job does NOT execute immediately (wait 1 second, verify `$test_result` is still nil). (5) Wait for scheduled time (total 6 seconds from enqueue). (6) Assert job executed after delay. (7) Verify workflow used `Workflow.sleep` (check workflow history for timer event using Temporal test client). This test proves durable scheduled execution works.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** RSpec integration test patterns, Temporal test server helper from I4.T2, adapter from I3.T2, workflow sleep logic from I2.T2
    *   **Input Files:**
        - `spec/support/temporal_test_server.rb`
        - `lib/activejob/temporal/adapter.rb`
        - `lib/activejob/temporal/workflows/aj_workflow.rb`
        - `spec/fixtures/sample_jobs.rb`
    *   **Target Files:**
        - `spec/integration/scheduled_jobs_spec.rb`
    *   **Deliverables:** Passing integration test for scheduled job execution
    *   **Acceptance Criteria:**
        - Integration test enqueues job with delay: `TestJob.set(wait: 5.seconds).perform_later(42)`
        - Test starts worker
        - Test verifies job does NOT execute immediately (check at T+1 second)
        - Test waits for scheduled time (T+6 seconds) and verifies job executed
        - Test queries workflow history for timer event (proves `Workflow.sleep` was used)
        - Test cleans up
        - `rake spec:integration` passes for scheduled_jobs_spec.rb
        - Test is isolated
    *   **Dependencies:** I3.T2 (Adapter enqueue_at), I2.T2 (AjWorkflow sleep logic), I4.T2 (Temporal test server)
    *   **Parallelizable:** No (integration test, depends on I3 and I4.T2)

<!-- anchor: task-i4-t5 -->
*   **Task 4.5: Write Integration Test - Retry Behavior**
    *   **Task ID:** `I4.T5`
    *   **Description:** Write integration test in `spec/integration/retries_spec.rb` that tests retry behavior for transient errors. Test flow: (1) Define a job that fails with `raise StandardError` on first execution, then succeeds on retry (use a counter: `$attempt_count ||= 0; $attempt_count += 1; raise StandardError if $attempt_count == 1; $test_result = 'success'`). (2) Configure job with `retry_on StandardError, wait: 1, attempts: 3`. (3) Enqueue job. (4) Start worker. (5) Wait for job to execute, fail, retry, and succeed. (6) Assert `$test_result == 'success'`. (7) Verify workflow history shows activity retry (check for activity failure + retry events). This test proves retry_on mapping works and Temporal retries activities.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** RSpec integration test patterns, Temporal test server, adapter, workflow, activity, retry mapper from I1.T6
    *   **Input Files:**
        - `spec/support/temporal_test_server.rb`
        - `lib/activejob/temporal/adapter.rb`
        - `lib/activejob/temporal/workflows/aj_workflow.rb`
        - `lib/activejob/temporal/activities/aj_runner_activity.rb`
        - `lib/activejob/temporal/retry_mapper.rb`
        - `spec/fixtures/sample_jobs.rb` (update with RetryableJob)
    *   **Target Files:**
        - `spec/integration/retries_spec.rb`
        - `spec/fixtures/sample_jobs.rb` (updated with RetryableJob)
    *   **Deliverables:** Passing integration test for retry behavior
    *   **Acceptance Criteria:**
        - Integration test defines a job that fails once then succeeds
        - Job uses `retry_on StandardError, wait: 1, attempts: 3`
        - Test enqueues job, starts worker
        - Test waits for job to fail, retry, and succeed (max 10 seconds)
        - Test asserts final result is 'success'
        - Test queries workflow history for activity failure + retry events
        - `rake spec:integration` passes for retries_spec.rb
        - Test is isolated
    *   **Dependencies:** I3.T1 (Adapter), I2.T3 (AjRunnerActivity error handling), I1.T6 (RetryMapper), I4.T2 (Temporal test server)
    *   **Parallelizable:** No (integration test, depends on I3 and I4.T2)

<!-- anchor: task-i4-t6 -->
*   **Task 4.6: Write Integration Test - Discard Behavior**
    *   **Task ID:** `I4.T6`
    *   **Description:** Write integration test in `spec/integration/retries_spec.rb` (same file, different test case) that tests discard_on behavior for non-retryable errors. Test flow: (1) Define a job that raises `FatalError` (custom exception class). (2) Configure job with `discard_on FatalError`. (3) Enqueue job. (4) Start worker. (5) Wait for job to execute and fail. (6) Verify job does NOT retry (workflow fails immediately). (7) Verify workflow history shows activity failed with non_retryable error. This test proves discard_on mapping works and errors are not retried.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** RSpec integration test patterns, Temporal test server, adapter, activity error mapping from I2.T3, retry mapper from I1.T6
    *   **Input Files:**
        - `spec/support/temporal_test_server.rb`
        - `lib/activejob/temporal/adapter.rb`
        - `lib/activejob/temporal/workflows/aj_workflow.rb`
        - `lib/activejob/temporal/activities/aj_runner_activity.rb`
        - `lib/activejob/temporal/retry_mapper.rb`
        - `spec/fixtures/sample_jobs.rb` (update with DiscardableJob and FatalError)
    *   **Target Files:**
        - `spec/integration/retries_spec.rb` (updated with discard test)
        - `spec/fixtures/sample_jobs.rb` (updated with DiscardableJob and FatalError)
    *   **Deliverables:** Passing integration test for discard_on behavior
    *   **Acceptance Criteria:**
        - Integration test defines a job that raises FatalError
        - Job uses `discard_on FatalError`
        - Test enqueues job, starts worker
        - Test waits for job to fail (max 5 seconds)
        - Test verifies job did NOT retry (workflow failed on first attempt)
        - Test queries workflow history for activity failed with non_retryable ApplicationError
        - `rake spec:integration` passes for discard test case in retries_spec.rb
        - Test is isolated
    *   **Dependencies:** I3.T1 (Adapter), I2.T3 (AjRunnerActivity error mapping), I1.T6 (RetryMapper), I4.T2 (Temporal test server)
    *   **Parallelizable:** No (integration test, depends on I3 and I4.T2)

<!-- anchor: task-i4-t7 -->
*   **Task 4.7: Write Integration Test - Cancellation**
    *   **Task ID:** `I4.T7`
    *   **Description:** Write integration test in `spec/integration/cancellation_spec.rb` that tests job cancellation. Test flow: (1) Define a long-running job that calls `Temporalio::Activity.heartbeat` periodically (e.g., `10.times { Temporalio::Activity.heartbeat; sleep 1 }`). (2) Enqueue job. (3) Start worker. (4) Wait for job to start executing (check workflow is running). (5) Call `ActiveJob::Temporal.cancel(TestJob, job_id)`. (6) Wait for workflow to be cancelled (max 5 seconds). (7) Verify workflow status is Cancelled. (8) Verify job did not complete (heartbeat loop interrupted). This test proves cancellation API works and activities can be aborted mid-execution via heartbeating.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** RSpec integration test patterns, Temporal test server, cancellation API from I3.T5, activity heartbeat documentation
    *   **Input Files:**
        - `spec/support/temporal_test_server.rb`
        - `lib/activejob/temporal/cancel.rb`
        - `lib/activejob/temporal/workflows/aj_workflow.rb`
        - `lib/activejob/temporal/activities/aj_runner_activity.rb`
        - `spec/fixtures/sample_jobs.rb` (update with LongRunningJob)
    *   **Target Files:**
        - `spec/integration/cancellation_spec.rb`
        - `spec/fixtures/sample_jobs.rb` (updated with LongRunningJob)
    *   **Deliverables:** Passing integration test for cancellation
    *   **Acceptance Criteria:**
        - Integration test defines a long-running job that heartbeats
        - Test enqueues job, starts worker
        - Test waits for workflow to start (query workflow status)
        - Test calls `ActiveJob::Temporal.cancel(LongRunningJob, job_id)`
        - Test waits for workflow to be cancelled (max 5 seconds)
        - Test verifies workflow status is Cancelled (query via test client)
        - Test verifies job did not complete (heartbeat loop was interrupted, no final result)
        - `rake spec:integration` passes for cancellation_spec.rb
        - Test is isolated
    *   **Dependencies:** I3.T5 (Cancellation API), I2.T3 (AjRunnerActivity), I4.T2 (Temporal test server)
    *   **Parallelizable:** No (integration test, depends on I3 and I4.T2)

<!-- anchor: task-i4-t8 -->
*   **Task 4.8: Write Integration Test - Search Attributes Visibility**
    *   **Task ID:** `I4.T8`
    *   **Description:** Write integration test in `spec/integration/enqueue_spec.rb` (same file, additional test) that verifies Search Attributes are attached to workflows. Test flow: (1) Enqueue a job (e.g., `TestJob.perform_later(42)`). (2) Start worker. (3) Wait for workflow to complete. (4) Query Temporal for the workflow using test client. (5) Verify workflow has Search Attributes: `ajClass == "TestJob"`, `ajQueue == "default"`, `ajJobId == job.job_id`, `ajEnqueuedAt` is a timestamp, `ajTenantId` is nil (or present if job has tenant context). This test proves Search Attributes builder works and attributes are persisted in Temporal.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** RSpec integration test patterns, Temporal test server, search attributes builder from I1.T7, Temporal search API documentation
    *   **Input Files:**
        - `spec/support/temporal_test_server.rb`
        - `lib/activejob/temporal/search_attributes.rb`
        - `lib/activejob/temporal/adapter.rb`
    *   **Target Files:**
        - `spec/integration/enqueue_spec.rb` (updated with search attributes test)
    *   **Deliverables:** Passing integration test verifying Search Attributes
    *   **Acceptance Criteria:**
        - Integration test enqueues job, starts worker
        - Test waits for workflow to complete
        - Test queries workflow details using test client (`client.get_workflow_handle(workflow_id).describe`)
        - Test verifies Search Attributes presence and values:
          - `ajClass` == job class name
          - `ajQueue` == job queue name (or "default")
          - `ajJobId` == job.job_id
          - `ajEnqueuedAt` is a timestamp (Time object or ISO8601 string)
          - `ajTenantId` is nil (or present if applicable)
        - `rake spec:integration` passes for search attributes test in enqueue_spec.rb
        - Test is isolated
    *   **Dependencies:** I3.T1 (Adapter with search attributes), I1.T7 (SearchAttributes builder), I4.T2 (Temporal test server)
    *   **Parallelizable:** No (integration test, depends on I3 and I4.T2)

<!-- anchor: task-i4-t9 -->
*   **Task 4.9: Run All Integration Tests and Verify Coverage**
    *   **Task ID:** `I4.T9`
    *   **Description:** Run `rake spec:integration` (or `rake spec` with integration tests included) to execute all integration tests written in Iteration 4. Verify all tests pass. Generate coverage report and ensure overall gem coverage (unit + integration) is >= 90%. If coverage is below target, identify gaps and write additional unit or integration tests. Acceptance: All integration tests pass, overall coverage >= 90%.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** RSpec configuration, SimpleCov, all integration tests from I4.T3-I4.T8
    *   **Input Files:**
        - `spec/spec_helper.rb`
        - `spec/integration/*.rb`
    *   **Target Files:** None (verification task, generates coverage report)
    *   **Deliverables:** Passing integration test suite, overall coverage report >= 90%
    *   **Acceptance Criteria:**
        - `rake spec:integration` (or `rake spec`) exits with status 0 (all integration tests pass)
        - SimpleCov report shows >= 90% overall code coverage (lib/ directory)
        - Coverage report includes both unit and integration test coverage
        - All integration tests run successfully with Temporal test server
        - No flaky tests (tests pass consistently on multiple runs)
    *   **Dependencies:** I4.T3, I4.T4, I4.T5, I4.T6, I4.T7, I4.T8 (all integration tests must be written)
    *   **Parallelizable:** No (must run after all tests are written)

<!-- anchor: task-i4-t10 -->
*   **Task 4.10: Run Rubocop on All Code**
    *   **Task ID:** `I4.T10`
    *   **Description:** Run `rake rubocop` on entire codebase (lib/, spec/, bin/). Fix any Rubocop offenses introduced in Iteration 4 (worker script, integration tests). Update `.rubocop.yml` if needed. Acceptance: `rake rubocop` passes with zero offenses across entire project.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Rubocop configuration, all code from I1-I4
    *   **Input Files:**
        - `lib/**/*.rb`
        - `spec/**/*.rb`
        - `bin/temporal-worker`
        - `.rubocop.yml`
    *   **Target Files:** All Ruby files (updated with style fixes)
    *   **Deliverables:** Clean codebase passing Rubocop checks
    *   **Acceptance Criteria:**
        - `rake rubocop` exits with status 0 (zero offenses)
        - All auto-correctable offenses are fixed
        - Any manual fixes are applied
        - Worker script (`bin/temporal-worker`) passes Rubocop checks
        - Integration test files pass Rubocop checks
    *   **Dependencies:** I4.T1 (Worker script), I4.T3-I4.T8 (Integration tests)
    *   **Parallelizable:** No (must run after all code is written)
