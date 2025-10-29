# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I4.T6",
  "iteration_id": "I4",
  "iteration_goal": "Implement the Temporal worker bootstrap script, write comprehensive integration tests with a real Temporal test server, and validate end-to-end functionality (enqueue → workflow → activity → job execution).",
  "description": "Write integration test in `spec/integration/retries_spec.rb` (same file, different test case) that tests discard_on behavior for non-retryable errors. Test flow: (1) Define a job that raises `FatalError` (custom exception class). (2) Configure job with `discard_on FatalError`. (3) Enqueue job. (4) Start worker. (5) Wait for job to execute and fail. (6) Verify job does NOT retry (workflow fails immediately). (7) Verify workflow history shows activity failed with non_retryable error. This test proves discard_on mapping works and errors are not retried.",
  "agent_type_hint": "BackendAgent",
  "inputs": "RSpec integration test patterns, Temporal test server, adapter, activity error mapping from I2.T3, retry mapper from I1.T6",
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
  "deliverables": "Passing integration test for discard_on behavior",
  "acceptance_criteria": "Integration test defines a job that raises FatalError; Job uses `discard_on FatalError`; Test enqueues job, starts worker; Test waits for job to fail (max 5 seconds); Test verifies job did NOT retry (workflow failed on first attempt); Test queries workflow history for activity failed with non_retryable ApplicationError; `rake spec:integration` passes for discard test case in retries_spec.rb; Test is isolated",
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

### Context: Non-Retryable Exceptions (discard_on) - Communication Flow (from 04_Behavior_and_Communication.md)

```markdown
**Non-Retryable Exceptions (`discard_on`):**

If the exception is in the `discard_on` list:

~~~plantuml
@startuml
participant "AjRunnerActivity" as Activity
participant "Job Class" as Job
participant "Error Mapper" as ErrorMapper
participant "Retry Mapper" as RetryMapper
participant "Temporal Cluster" as Temporal

Activity -> Job : job.perform(42)
Job --> Activity : raise PSP::FatalError

Activity -> ErrorMapper : map_exception(error, job_class)
ErrorMapper -> RetryMapper : discard_exception?(SendInvoiceJob, error)
RetryMapper --> ErrorMapper : true (in discard_on list)

ErrorMapper --> Activity : Raise ApplicationError(\n  message: "Fatal error",\n  non_retryable: true,\n  cause: error\n)

Activity --> Temporal : Activity failed (non-retryable)
Temporal -> Temporal : Mark activity as Failed (no retry)
Temporal -> Temporal : Workflow fails (activity failure bubbles up)

@enduml
~~~
```

**Key Flow Summary:**
- When a job raises an exception that matches `discard_on`, the `AjRunnerActivity` queries `RetryMapper.discard_exception?(job_class, error)`
- If it returns `true`, the activity re-raises the exception as `Temporalio::Activity::ApplicationError` with `non_retryable: true`
- This signals to Temporal that the activity should NOT be retried
- The workflow then fails immediately (activity failure bubbles up to workflow)

### Context: Retry Policy Data Model (from 03_System_Structure_and_Data.md)

```markdown
**3. Retry Policy (Activity Configuration)**

Derived from ActiveJob's `retry_on`/`discard_on` DSL and passed to `execute_activity`.

| Field | Type | Source | Example |
|-------|------|--------|---------|
| `initial_interval` | Duration | `retry_on wait:` or config default | `30.seconds` |
| `backoff_coefficient` | Float | Config default (2.0) | `2.0` |
| `maximum_attempts` | Integer | `retry_on attempts:` or config default | `5` |
| `non_retryable_error_types` | Array<String> | `discard_on` exception classes | `["PSP::FatalError"]` |
```

**Key Insight:**
- The `discard_on` declarations are converted to an array of exception class **names** (strings) in the `non_retryable_error_types` field
- This array is passed to Temporal's `RetryPolicy` when the workflow starts the activity
- When an activity raises an exception with `non_retryable: true`, Temporal does NOT retry it

### Context: Component Error Mapping (from 03_System_Structure_and_Data.md)

```markdown
Container_Boundary(activity_boundary, "AjRunnerActivity") {
  Component(job_instantiator, "JobInstantiator", "Ruby Method", "Deserializes payload, creates job instance")
  Component(error_mapper, "ErrorMapper", "Ruby Module", "Maps discard_on → ApplicationError(non_retryable)")
  Component(idempotency_key, "IdempotencyKeyProvider", "Ruby Module", "Sets Thread.current[:aj_temporal_idempotency_key]")
}

Component_Ext(retry_mapper_module, "Retry Mapper", "Ruby Module", "for(job_class), discard_exception?")

Rel(error_mapper, retry_mapper_module, "Calls discard_exception?", "Ruby")
```

**Key Component:**
- The `error_mapper` logic is built into `AjRunnerActivity.handle_exception` method
- It calls `RetryMapper.discard_exception?(job_class, exception)` to determine if the exception should be discarded
- If true, it raises `Temporalio::Activity::ApplicationError.new(..., non_retryable: true)`

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal/activities/aj_runner_activity.rb`
    *   **Summary:** This file contains the Temporal activity that executes ActiveJob jobs. It includes the critical `handle_exception` method (lines 99-109) which implements the error mapping logic for `discard_on` behavior.
    *   **Recommendation:** You MUST understand the exact behavior of `handle_exception`. When `RetryMapper.discard_exception?(job_class, error)` returns `true`, the method raises `Temporalio::Activity::ApplicationError` with `non_retryable: true`. This is the core mechanism you are testing.
    *   **Code Reference:** Lines 99-109 show the exact exception handling logic:
        ```ruby
        def handle_exception(job_class, error)
          if job_class && RetryMapper.discard_exception?(job_class, error)
            raise Temporalio::Activity::ApplicationError.new(
              error.message,
              non_retryable: true,
              cause: error
            )
          end

          raise error
        end
        ```

*   **File:** `lib/activejob/temporal/retry_mapper.rb`
    *   **Summary:** This module maps ActiveJob's `retry_on`/`discard_on` declarations to Temporal's `RetryPolicy`. The key method for this task is `discard_exception?(job_class, exception)` (lines 22-28).
    *   **Recommendation:** Your test job MUST declare `discard_on FatalError` (or similar custom exception class). The RetryMapper will inspect the job class's rescue handlers and determine if the raised exception matches any `discard_on` declarations. The matching is done via inheritance check (line 156): `candidate_class <= handler_class`.
    *   **Implementation Detail:** The `discard_exception?` method returns `true` if the exception or any of its ancestors match a `discard_on` declaration (lines 25-27).

*   **File:** `spec/integration/retries_spec.rb`
    *   **Summary:** This is the existing integration test file for retry behavior. It currently contains ONE test case for successful retry behavior (`RetryTestJob`). You MUST ADD a second test case to this same file.
    *   **Recommendation:** Follow the exact same test structure: use `around` block for setup/teardown (lines 11-23), start a worker (line 26), enqueue job, wait for workflow failure, verify workflow status is FAILED (not COMPLETED), and check workflow history for non-retryable error evidence.
    *   **Critical Pattern:** The existing test uses `wait_for_result("success")` and `wait_for_workflow_completion(workflow_id)`. For your test, you'll need a helper to wait for workflow FAILURE instead of completion. Consider a `wait_for_workflow_failure(workflow_id)` method that checks for `WorkflowExecutionStatus::FAILED` status.

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** This file contains sample job classes for testing. Several discard-related jobs already exist: `DiscardableJob` (lines 40-43), `DiscardOnlyJob` (lines 45-47), and exception classes `FatalJobError` and `DerivedFatalJobError` (lines 32-33).
    *   **Recommendation:** You SHOULD create a new test job class specifically for this integration test. Name it `DiscardTestJob` or similar. It MUST inherit from `ActiveJob::Base`, declare `discard_on FatalJobError` (or create a new exception class like `NonRetryableTestError`), and raise that exception in its `perform` method. DO NOT reuse `DiscardableJob` as it has both `retry_on` and `discard_on` which could complicate the test.
    *   **Example Pattern:**
        ```ruby
        class NonRetryableTestError < StandardError; end

        class DiscardTestJob < ActiveJob::Base
          discard_on NonRetryableTestError
          queue_as :default

          def perform
            raise NonRetryableTestError, "This error should not be retried"
          end
        end
        ```

*   **File:** `spec/support/temporal_test_server.rb`
    *   **Summary:** Helper module that manages Temporal test server connection for integration tests. Provides `TemporalTestHelper.client` method.
    *   **Recommendation:** You MUST use `TemporalTestHelper.client` to get the Temporal client for querying workflow status and history. This is already done correctly in the existing test (line 9).

*   **File:** `lib/activejob/temporal/workflows/aj_workflow.rb`
    *   **Summary:** The Temporal workflow that orchestrates job execution. It passes the `RetryPolicy` (with `non_retryable_error_types`) to the activity when calling `execute_activity` (lines 23-27).
    *   **Note:** You don't need to modify this file. It's relevant because when your test job is enqueued, the workflow will automatically include the `non_retryable_error_types` from the `discard_on` declaration in the RetryPolicy passed to the activity.

### Implementation Tips & Notes

*   **Tip #1: Workflow Status Check**
    The key difference between this test and the retry test is the expected workflow status. The retry test expects `WorkflowExecutionStatus::COMPLETED`, but your test MUST verify `WorkflowExecutionStatus::FAILED`. Create a helper method similar to `wait_for_workflow_completion` but check for FAILED status instead.

*   **Tip #2: Activity Attempt Count**
    For the discard test, the activity should execute only ONCE (attempt 1), then fail with non-retryable error. You can verify this by checking the workflow history:
    ```ruby
    activity_started_event = history.events.find { |e| e.event_type == :EVENT_TYPE_ACTIVITY_TASK_STARTED }
    expect(activity_started_event.activity_task_started_event_attributes.attempt).to eq(1)
    ```

*   **Tip #3: Workflow History Verification**
    You MUST check the workflow history to prove the activity failed with a non-retryable error. Look for these event types:
    - `:EVENT_TYPE_ACTIVITY_TASK_SCHEDULED` - activity was scheduled
    - `:EVENT_TYPE_ACTIVITY_TASK_STARTED` - activity execution began
    - `:EVENT_TYPE_ACTIVITY_TASK_FAILED` - activity failed
    - `:EVENT_TYPE_WORKFLOW_EXECUTION_FAILED` - workflow failed (due to activity failure)

    The activity failed event will contain details about the non-retryable error.

*   **Tip #4: Timeout Value**
    Since the job should fail immediately (no retries), use a shorter timeout than the retry test. The acceptance criteria specifies "max 5 seconds" (vs 10 seconds for retry test). Adjust your `wait_for_workflow_failure` helper accordingly:
    ```ruby
    def wait_for_workflow_failure(workflow_id)
      Timeout.timeout(5) do
        loop do
          handle = client.workflow_handle(workflow_id)
          description = handle.describe
          break if description.status == Temporalio::Client::WorkflowExecutionStatus::FAILED

          sleep 0.1
        end
      end
    end
    ```

*   **Tip #5: Global Variable Management**
    The existing test uses `$attempt_count` and `$test_result` global variables. For your test, you may NOT need these since you're verifying failure, not success. However, if you want to prove the job executed exactly once, you could use `$discard_test_executed = true` to verify the job's perform method was called. Reset it in the `around` block's ensure clause.

*   **Tip #6: Test Isolation**
    The `around` block ensures proper cleanup. Make sure your test follows this pattern to avoid test pollution. The existing test already handles worker cleanup via `stop_worker(@worker_thread)` in the ensure block (line 20).

*   **Warning: ApplicationError Details**
    When querying the workflow history, the activity failed event will show the `ApplicationError` with `non_retryable: true`. Temporal SDK may represent this as a specific error type or attribute in the event. You may need to inspect the actual event structure in your test to verify the non-retryable flag. Refer to the Temporal Ruby SDK documentation for the exact event attribute structure.

*   **Note: Job Definition Location**
    Add your new `DiscardTestJob` (or `NonRetryableTestJob`) to `spec/fixtures/sample_jobs.rb` at the end of the file, following the existing pattern. Ensure it's an `ActiveJob::Base` subclass, not a plain `ApplicationJob`, since `discard_on` is an ActiveJob feature.

### Test Structure Recommendation

Based on the existing retry test, your discard test should follow this structure:

1. **Test name:** `"discards non-retryable errors according to discard_on configuration"`
2. **Setup:** Start worker, enqueue `DiscardTestJob`
3. **Wait:** Call `wait_for_workflow_failure(workflow_id)` with 5-second timeout
4. **Verify workflow status:** `expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::FAILED)`
5. **Verify activity attempt count:** Should be 1 (no retries)
6. **Verify workflow history:** Should include `EVENT_TYPE_ACTIVITY_TASK_FAILED` and `EVENT_TYPE_WORKFLOW_EXECUTION_FAILED`
7. **Cleanup:** Stop worker in ensure block

---

## Summary

You are implementing Task I4.T6: an integration test for `discard_on` behavior that proves non-retryable errors are NOT retried by Temporal. The test MUST:
- Define a new job class with `discard_on FatalError` (or similar custom exception)
- Enqueue the job and start a worker
- Wait for the workflow to FAIL (not complete)
- Verify the activity executed only once (no retries)
- Check the workflow history for non-retryable error evidence

All necessary infrastructure (test server helper, worker setup, existing test patterns) is already in place. You are ADDING a second test case to the existing `spec/integration/retries_spec.rb` file and potentially adding a new job class to `spec/fixtures/sample_jobs.rb`.
