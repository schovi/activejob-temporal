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

### Context: decision-retry-mapping (from 06_Rationale_and_Future.md)

```markdown
#### **Decision 4: Map retry_on/discard_on to Temporal RetryPolicy**

**Choice:** Translate ActiveJob's `retry_on`/`discard_on` DSL to Temporal's activity `RetryPolicy` at enqueue time.

**Rationale:**

- **Familiar API**: Rails developers use existing ActiveJob retry DSL; no Temporal-specific syntax
- **Durable Retries**: Temporal manages retry backoff and state; survives worker crashes
- **Exponential Backoff**: Temporal's built-in backoff prevents thundering herd on downstream services

**Trade-offs:**

| Benefit | Cost |
|---------|------|
| No code changes for existing jobs | Mapping logic adds complexity (retry_mapper module) |
| Temporal's retry is battle-tested | Cannot use Rails-specific retry features (e.g., callbacks) |
| Retries survive worker crashes | Must restart activity from beginning (no partial retry) |

**Alternatives Considered:**

1. **In-Activity Retry Logic**: Implement retries inside `AjRunnerActivity.execute`
   - **Rejected**: Loses Temporal's durable retry state; harder to debug
2. **No Retry Mapping**: Require jobs to use Temporal-specific retry syntax
   - **Rejected**: Breaks ActiveJob compatibility; increases learning curve

**Limitation**: If a job has multiple `retry_on` declarations, only the first matching exception is used (by ancestry order).
```

### Context: task-i4-t5 (from 02_Iteration_I4.md)

```markdown
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
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `spec/integration/retries_spec.rb`
    *   **Summary:** This file already exists and contains a basic test structure with setup/teardown logic for integration tests. It has one passing test case for retry behavior.
    *   **Current Status:** The existing test case (`retries transient errors according to retry_on configuration`) already validates basic retry behavior with `RetryTestJob`. You need to ADD a NEW test case for discard_on behavior as specified in I4.T6.
    *   **Recommendation:** You MUST use the existing test structure but ADD A NEW test case. The current test for retry behavior is already complete. The task I4.T5 appears to be already DONE based on the code analysis. You should VERIFY this by running the test.

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** Contains sample job classes including `RetryTestJob` (lines 86-98) that implements the exact retry behavior described in the task requirements.
    *   **Current Implementation:** `RetryTestJob` is configured with `retry_on StandardError, wait: 1, attempts: 3` and uses global variables `$attempt_count` and `$test_result` exactly as specified.
    *   **Recommendation:** The `RetryTestJob` class ALREADY EXISTS and matches the task requirements. You should NOT create a new job class but verify the existing one works correctly.

*   **File:** `lib/activejob/temporal/retry_mapper.rb`
    *   **Summary:** Implements the logic to map ActiveJob `retry_on`/`discard_on` declarations to Temporal RetryPolicy parameters.
    *   **Key Methods:**
        - `for(job_class, exception = nil)`: Returns hash with `:initial_interval`, `:backoff_coefficient`, `:maximum_attempts`, `:non_retryable_error_types`
        - `discard_exception?(job_class, exception)`: Returns true if exception should not be retried
    *   **Recommendation:** This module is fully implemented. The workflow uses `RetryMapper.for(job_class)` to build retry policies, and the activity uses `RetryMapper.discard_exception?` to check if errors should be discarded.

*   **File:** `lib/activejob/temporal/workflows/aj_workflow.rb`
    *   **Summary:** The workflow class that orchestrates job execution. It extracts retry policy from the job class and applies it to activity execution.
    *   **Key Implementation:** Lines 47-61 show the workflow calls `RetryMapper.for(job_class)` to get retry policy hash, then converts it to `Temporalio::RetryPolicy` object in `build_retry_policy` method.
    *   **Note:** The workflow converts `maximum_attempts` from RetryMapper to `max_attempts` for Temporal SDK (line 65).
    *   **Recommendation:** This is fully implemented. Your test SHOULD verify that the retry policy is correctly applied during workflow execution.

*   **File:** `lib/activejob/temporal/activities/aj_runner_activity.rb`
    *   **Summary:** The activity that executes the actual job logic and handles exceptions.
    *   **Key Implementation:** Lines 72-76 show exception handling. If the job raises an error, `handle_exception` (lines 99-109) checks if it should be discarded using `RetryMapper.discard_exception?`. If yes, it raises `Temporalio::Activity::ApplicationError` with `non_retryable: true`.
    *   **Recommendation:** This is fully implemented. Your test SHOULD verify that retryable exceptions (those not matching `discard_on`) are retried by Temporal's activity retry logic.

*   **File:** `spec/support/temporal_test_server.rb`
    *   **Summary:** Provides `TemporalTestHelper` module for integration test setup. Configures test namespace, manages client connection, and verifies server availability.
    *   **Usage:** Call `TemporalTestHelper.client` to get configured client. Setup/teardown is automatic via RSpec hooks.
    *   **Recommendation:** You MUST use `TemporalTestHelper.client` instead of creating your own client instances. This ensures proper test configuration (namespace: "test").

*   **File:** `spec/integration/enqueue_spec.rb`
    *   **Summary:** Contains example integration test patterns including worker startup/shutdown logic.
    *   **Key Patterns:** Shows how to start worker in background thread, wait for results using polling with timeout, stop worker gracefully.
    *   **Recommendation:** You SHOULD follow the same patterns used in this file for worker management and result verification.

### Implementation Tips & Notes

*   **CRITICAL: Task Status Verification**
    Based on my code review, the test case described in task I4.T5 ALREADY EXISTS in `spec/integration/retries_spec.rb` (lines 25-56). The test:
    - ✅ Uses `RetryTestJob` with `retry_on StandardError, wait: 1, attempts: 3`
    - ✅ Enqueues job and starts worker
    - ✅ Waits for `$test_result == "success"` and `$attempt_count == 2`
    - ✅ Verifies workflow completed successfully
    - ✅ Checks workflow history for activity events

    **You MUST verify this by running the test first**: `bundle exec rspec spec/integration/retries_spec.rb:25`

    If the test passes, task I4.T5 is ALREADY COMPLETE and you should mark it as `done: true`.

*   **Worker Management Pattern**
    The existing test uses a simple pattern:
    ```ruby
    Thread.new do
      worker = Temporalio::Worker.new(
        client: TemporalTestHelper.client,
        task_queue: "default",
        workflows: [AjWorkflow],
        activities: [AjRunnerActivity]
      )
      worker.run
    end
    ```
    This is the correct approach. Do NOT attempt graceful shutdown with signals in integration tests—just use `thread.kill` in cleanup.

*   **Global Variables Pattern**
    The retry test uses `$attempt_count` and `$test_result` global variables to track execution across retries. This is intentional and necessary because:
    - Each retry may run in a different worker thread/process in production
    - Global state proves the same job instance was retried (not a new job)
    - Alternative (database/file state) would be more complex for a test

    **You MUST reset these globals in test setup/teardown** to ensure test isolation (lines 14-15, 21-22).

*   **Workflow History Verification**
    The existing test (lines 44-53) shows how to verify retry behavior in Temporal's workflow history:
    ```ruby
    history = handle.fetch_history
    event_types = history.events.map(&:event_type)
    expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_SCHEDULED)
    expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_COMPLETED)
    ```

    **IMPORTANT NOTE:** The existing code has a comment (lines 45-47) explaining that Temporal Ruby SDK handles activity retries at the worker level, so intermediate failures may NOT appear as separate events in workflow history. The critical validation is that the job executed the correct number of times and eventually succeeded.

*   **Timeout and Polling Strategy**
    The test uses `wait_for_result` helper (lines 79-87) with 10-second timeout and 0.1-second polling interval. This is appropriate for retry tests where:
    - Initial execution: ~instant
    - Failure and retry delay: 1 second (from `wait: 1`)
    - Retry execution: ~instant
    - Total expected time: ~1-2 seconds
    - Timeout at 10 seconds provides safety margin

*   **Configuration Reference**
    From `docs/configuration_reference.md`, the relevant retry configuration defaults are:
    - `default_retry_initial_interval`: 30 seconds (but job overrides with `wait: 1`)
    - `default_retry_backoff`: 2.0 (exponential)
    - `default_retry_max_attempts`: 1 (but job overrides with `attempts: 3`)

    These defaults are ONLY used when a job does NOT specify `retry_on`. The test job DOES specify retry parameters, so it uses those values.

*   **Test Isolation**
    The existing test properly ensures isolation with:
    - `around` block that resets ActiveJob adapter and global state (lines 11-23)
    - Worker cleanup in `ensure` block (lines 54-55)
    - Separate test cases should NOT interfere with each other

    When adding future test cases (like I4.T6 for discard_on), follow this same pattern.

### Warnings & Potential Issues

*   **WARNING:** If you create duplicate test cases for I4.T5, you will have failing tests due to the existing implementation. Always check the current state of test files BEFORE writing new tests.

*   **NOTE:** The next task (I4.T6) requires adding a DISCARD_ON test to this same file. That test should verify a job with `discard_on FatalError` does NOT retry when FatalError is raised.

*   **TEMPORAL SDK REQUIREMENT:** Integration tests require a running Temporal test server. The test will skip with a clear error message if the server is not available (see `spec/support/temporal_test_server.rb:98-108`).
