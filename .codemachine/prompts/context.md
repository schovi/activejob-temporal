# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I4.T5",
  "iteration_id": "I4",
  "iteration_goal": "Implement the Temporal worker bootstrap script, write comprehensive integration tests with a real Temporal test server, and validate end-to-end functionality (enqueue → workflow → activity → job execution).",
  "description": "Write integration test in `spec/integration/retries_spec.rb` that tests retry behavior for transient errors. Test flow: (1) Define a job that fails with `raise StandardError` on first execution, then succeeds on retry (use a counter: `$attempt_count ||= 0; $attempt_count += 1; raise StandardError if $attempt_count == 1; $test_result = 'success'`). (2) Configure job with `retry_on StandardError, wait: 1, attempts: 3`. (3) Enqueue job. (4) Start worker. (5) Wait for job to execute, fail, retry, and succeed. (6) Assert `$test_result == 'success'`. (7) Verify workflow history shows activity retry (check for activity failure + retry events). This test proves retry_on mapping works and Temporal retries activities.",
  "agent_type_hint": "BackendAgent",
  "inputs": "RSpec integration test patterns, Temporal test server, adapter, workflow, activity, retry mapper from I1.T6",
  "target_files": [
    "spec/integration/retries_spec.rb",
    "spec/fixtures/sample_jobs.rb"
  ],
  "input_files": [
    "spec/support/temporal_test_server.rb",
    "lib/activejob/temporal/adapter.rb",
    "lib/activejob/temporal/workflows/aj_workflow.rb",
    "lib/activejob/temporal/activities/aj_runner_activity.rb",
    "lib/activejob/temporal/retry_mapper.rb",
    "spec/fixtures/sample_jobs.rb"
  ],
  "deliverables": "Passing integration test for retry behavior",
  "acceptance_criteria": "Integration test defines a job that fails once then succeeds; Job uses `retry_on StandardError, wait: 1, attempts: 3`; Test enqueues job, starts worker; Test waits for job to fail, retry, and succeed (max 10 seconds); Test asserts final result is 'success'; Test queries workflow history for activity failure + retry events; `rake spec:integration` passes for retries_spec.rb; Test is isolated",
  "dependencies": [
    "I3.T1",
    "I2.T3",
    "I1.T6",
    "I4.T2"
  ],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: Error Handling (Activity Retries) (from 04_Behavior_and_Communication.md)

```markdown
**Error Handling (Activity Retries):**

If `job.perform` raises an exception, the following flow occurs:

1. **Exception raised**: Job raises an error (e.g., `PSP::TransientError`)
2. **Activity catches error**: `AjRunnerActivity.execute` catches the exception
3. **Check discard_on**: Activity calls `RetryMapper.discard_exception?(job_class, error)` to determine if the error is non-retryable
4. **Retryable error path** (if `discard_exception?` returns `false`):
   - Activity re-raises the original exception
   - Temporal receives the activity failure
   - Temporal checks the `RetryPolicy` (from `retry_on` mapping): attempt 1/5, wait 30s
   - Temporal sleeps 30s (durable timer)
   - Temporal schedules activity retry (attempt 2)
   - Activity will be retried up to 5 times with exponential backoff (30s, 60s, 120s, ...)

**Non-Retryable Exceptions (`discard_on`):**

If the exception is in the `discard_on` list:

1. **Exception raised**: Job raises a fatal error (e.g., `PSP::FatalError`)
2. **Activity catches error**: `AjRunnerActivity.execute` catches the exception
3. **Check discard_on**: Activity calls `RetryMapper.discard_exception?(job_class, error)` → returns `true`
4. **Non-retryable error path**:
   - Activity raises `Temporalio::Activity::ApplicationError` with `non_retryable: true`
   - Temporal receives activity failure marked as non-retryable
   - Temporal marks activity as Failed (no retry)
   - Workflow fails (activity failure bubbles up)
```

### Context: retry_on/discard_on Mapping (from Architecture)

```markdown
**Retry Policy Mapping:**

The `RetryMapper` module translates ActiveJob's `retry_on` and `discard_on` declarations to Temporal's `RetryPolicy`:

- **retry_on parameters**:
  - `wait` (seconds or duration) → `initial_interval` in RetryPolicy
  - `attempts` (integer or `:unlimited`) → `maximum_attempts` in RetryPolicy (0 for unlimited)
  - `exceptions` (array of exception classes) → Determines which errors trigger retry

- **discard_on parameters**:
  - `exceptions` (array of exception classes) → `non_retryable_error_types` in RetryPolicy
  - Errors matching discard_on are converted to `ApplicationError(non_retryable: true)` by the activity

- **Default values** (from configuration):
  - `default_retry_initial_interval`: 30 seconds
  - `default_retry_backoff`: 2.0 (exponential backoff coefficient)
  - `default_retry_max_attempts`: 1 (no retries by default)
```

### Context: Integration Test Patterns (from existing specs)

The existing integration tests follow this pattern:

1. **Setup**: Configure ActiveJob adapter to `:temporal`, reset test state
2. **Enqueue job**: Use `TestJob.perform_later(arg)` or `TestJob.set(wait: ...).perform_later(arg)`
3. **Start worker**: Create worker thread polling the "default" task queue
4. **Wait for result**: Use `Timeout.timeout(10)` with polling loop checking for expected result
5. **Verify result**: Assert job executed correctly (e.g., `TestJob.last_argument == expected`)
6. **Verify workflow state**: Query workflow handle via `client.workflow_handle(workflow_id).describe`
7. **Verify workflow history** (optional): Fetch workflow history to check for specific events (e.g., timer events, activity retries)
8. **Cleanup**: Stop worker thread, restore adapter, reset test state

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** This file contains sample job classes for testing, including jobs with `retry_on` and `discard_on` configurations. It already defines `RetryableJob` (with `retry_on SampleJobError, wait: 60.seconds, attempts: 5`) and other sample jobs.
    *   **Recommendation:** You SHOULD add a new test job class to this file that uses `retry_on StandardError, wait: 1, attempts: 3` as specified in the task. This job should use a global variable to track attempts and fail on the first attempt, then succeed on retry.
    *   **Tip:** The file already uses global variables for tracking state (e.g., `TestJob.last_argument`). You can follow this pattern with `$attempt_count` for tracking retry attempts.

*   **File:** `spec/integration/enqueue_spec.rb`
    *   **Summary:** This file demonstrates the basic integration test pattern: setting up the adapter, starting a worker, enqueuing a job, waiting for results, and verifying workflow state.
    *   **Recommendation:** You MUST follow the same test structure as this file. Use the `around` block to configure the adapter and clean up after the test. Use the same helper methods (`start_worker`, `stop_worker`, `wait_for_result`).
    *   **Note:** This file uses `TestJob.last_argument` as a class-level variable to communicate between the activity and the test. Your retry test should use a similar pattern with `$test_result` as specified in the task.

*   **File:** `spec/integration/scheduled_jobs_spec.rb`
    *   **Summary:** This file demonstrates how to verify workflow history by fetching events and checking for specific event types (e.g., `:EVENT_TYPE_TIMER_STARTED`).
    *   **Recommendation:** You MUST use a similar approach to verify activity retries. After the job succeeds, fetch the workflow history using `handle.fetch_history` and check for activity failure/retry events.
    *   **Tip:** Look for event types related to activity execution and failure. The Temporal SDK's event types include things like `:EVENT_TYPE_ACTIVITY_TASK_SCHEDULED`, `:EVENT_TYPE_ACTIVITY_TASK_FAILED`, `:EVENT_TYPE_ACTIVITY_TASK_STARTED`. You should verify that the activity failed at least once (indicating a retry occurred).

*   **File:** `spec/support/temporal_test_server.rb`
    *   **Summary:** This file provides the `TemporalTestHelper` module that manages Temporal test server connection and configuration. It handles client setup, namespace configuration, and connection verification.
    *   **Recommendation:** You MUST use `TemporalTestHelper.client` to get the Temporal client for your test. The test server setup is handled automatically by RSpec hooks.
    *   **Note:** The helper configures the test namespace as "test" and uses the target from `TEMPORAL_TEST_TARGET` env var (default: 127.0.0.1:7233).

*   **File:** `lib/activejob/temporal/retry_mapper.rb`
    *   **Summary:** This file implements the logic for translating `retry_on`/`discard_on` to Temporal's RetryPolicy. It inspects the job class's rescue handlers and extracts retry parameters.
    *   **Recommendation:** Your test job MUST use ActiveJob's standard `retry_on` declaration. The RetryMapper will automatically convert this to the appropriate Temporal RetryPolicy when the job is enqueued.
    *   **Important:** The `wait` parameter in `retry_on` is converted to seconds. Since you need `wait: 1` (second), you can write `retry_on StandardError, wait: 1, attempts: 3` or `retry_on StandardError, wait: 1.second, attempts: 3`.

*   **File:** `lib/activejob/temporal/activities/aj_runner_activity.rb`
    *   **Summary:** This file defines the activity that executes the job. It catches exceptions, checks if they're discardable using `RetryMapper.discard_exception?`, and either re-raises (for retry) or raises `ApplicationError(non_retryable: true)` (for discard).
    *   **Recommendation:** You don't need to modify this file. The existing error handling logic will correctly propagate the `StandardError` for retry.
    *   **Note:** The activity sets `Thread.current[:aj_temporal_idempotency_key]` before execution and clears it in an ensure block. This is already implemented.

*   **File:** `lib/activejob/temporal/workflows/aj_workflow.rb`
    *   **Summary:** This file defines the workflow that orchestrates job execution. It optionally sleeps (for scheduled jobs) and then executes the activity with the retry policy from the payload.
    *   **Recommendation:** You don't need to modify this file. The workflow already passes the `retry_policy` from the payload to the activity execution options.
    *   **Note:** The retry policy is added to the payload by the adapter (in `lib/activejob/temporal/adapter.rb` line 85).

*   **File:** `lib/activejob/temporal/adapter.rb`
    *   **Summary:** This file defines the ActiveJob adapter that enqueues jobs to Temporal. It builds the payload, including the retry policy from `RetryMapper.for(job.class)`.
    *   **Recommendation:** You don't need to modify this file. The adapter already integrates retry policy mapping when building the payload.
    *   **Tip:** Line 85 shows: `payload[:retry_policy] = ActiveJob::Temporal::RetryMapper.for(job.class)`. This ensures your test job's `retry_on` configuration is automatically converted to a Temporal RetryPolicy.

### Implementation Tips & Notes

*   **Tip:** Use a global variable for tracking retry attempts because the job instance is recreated on each retry attempt. A class variable on the job won't work as expected since each activity execution creates a new job instance.
    ```ruby
    $attempt_count = 0  # Initialize before test

    class RetryTestJob < ActiveJob::Base
      retry_on StandardError, wait: 1, attempts: 3

      def perform
        $attempt_count += 1
        raise StandardError, "Transient error" if $attempt_count == 1
        $test_result = "success"
      end
    end
    ```

*   **Tip:** In your test's `around` block, reset `$attempt_count = 0` and `$test_result = nil` before running the test and in the ensure block to maintain test isolation.

*   **Tip:** The `wait: 1` means Temporal will wait 1 second between retries. With exponential backoff (coefficient 2.0), retries will happen at approximately: T+0s (initial failure), T+1s (retry 1 fails), T+3s (retry 2 succeeds). Your total test timeout of 10 seconds is sufficient.

*   **Tip:** To verify activity retries in workflow history, look for these event types:
    - `:EVENT_TYPE_ACTIVITY_TASK_SCHEDULED` - Activity was scheduled
    - `:EVENT_TYPE_ACTIVITY_TASK_STARTED` - Activity started executing
    - `:EVENT_TYPE_ACTIVITY_TASK_FAILED` - Activity failed (this indicates a retry occurred)
    - `:EVENT_TYPE_ACTIVITY_TASK_COMPLETED` - Activity succeeded

    You should see multiple `ACTIVITY_TASK_STARTED` events (indicating retries) and at least one `ACTIVITY_TASK_FAILED` event (the initial failure).

*   **Warning:** Make sure to stop the worker thread in the `ensure` block of your `around` hook. Leaving worker threads running can cause test interference and resource leaks.

*   **Note:** The existing `wait_for_result` helper in `enqueue_spec.rb` uses a polling loop with `sleep 0.1`. You should implement a similar helper in your spec or verify that your result variable is being set correctly by the activity execution.

*   **Important:** Your test MUST define a job that fails exactly once and then succeeds. Don't make it fail on all three attempts, as that would result in workflow failure rather than demonstrating successful retry behavior. The task description explicitly states: "fails with `raise StandardError` on first execution, then succeeds on retry".

*   **Testing Best Practice:** After asserting the final result (`$test_result == "success"`), also assert that `$attempt_count == 2` to confirm the job executed exactly twice (initial failure + successful retry). This provides stronger verification of retry behavior.

### Expected Test Structure

Your test file should follow this structure:

```ruby
# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

RSpec.describe "ActiveJob Temporal retry behavior", :integration do
  let(:client) { TemporalTestHelper.client }

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal
    $attempt_count = 0
    $test_result = nil

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    stop_worker(@worker_thread)
    $attempt_count = 0
    $test_result = nil
  end

  it "retries transient errors according to retry_on configuration" do
    # 1. Enqueue the job
    # 2. Start worker
    # 3. Wait for job to complete (with retries)
    # 4. Assert $test_result == "success"
    # 5. Assert $attempt_count == 2 (failed once, succeeded once)
    # 6. Verify workflow status is COMPLETED
    # 7. Verify workflow history shows activity retry events
  end

  private

  def start_worker
    # Similar to enqueue_spec.rb
  end

  def stop_worker(thread)
    # Similar to enqueue_spec.rb
  end

  def wait_for_result(expected)
    # Similar to enqueue_spec.rb, but checking $test_result
  end
end
```

### Common Pitfalls to Avoid

1. **Don't use instance variables on the job class** - Each retry creates a new job instance, so instance variables won't persist across retries.

2. **Don't forget to reset global state** - Always reset `$attempt_count` and `$test_result` in both the setup and cleanup phases to ensure test isolation.

3. **Don't make the job fail on every attempt** - The job should fail only on the first attempt (when `$attempt_count == 1`), then succeed on subsequent attempts.

4. **Don't use `wait: 60.seconds`** - The task specifies `wait: 1` (or 1 second) to keep test execution fast. Don't copy the 60-second wait from the existing `RetryableJob` fixture.

5. **Don't forget to query workflow history** - One of the acceptance criteria is verifying workflow history shows activity failure + retry events. You must fetch the history and check event types.

6. **Don't assume worker is immediately ready** - In integration tests with real Temporal, there's a small delay between starting the worker and it being ready to process tasks. The existing tests handle this correctly by using `wait_for_result` with a timeout.
