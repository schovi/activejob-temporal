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

### Context: communication-error-handling (from 04_Behavior_and_Communication.md)

```markdown
#### **Communication Error Handling**

**Execution-Time Errors:**

| Error Scenario | Handling | Outcome |
|----------------|----------|---------|
| Activity timeout (>15min) | Temporal raises `Temporalio::Activity::TimeoutError` | Activity fails, workflow retries per `RetryPolicy` |
| Worker crash during activity | Temporal detects heartbeat timeout | Activity scheduled on another worker |
| Exception in `job.perform` | Caught by `AjRunnerActivity`, mapped to `ApplicationError` | Retried per `retry_on` or marked non-retryable per `discard_on` |
| Workflow code bug (non-determinism) | Temporal raises `Temporalio::Workflow::NondeterminismError` | Workflow stuck, requires code fix + reset |
```

### Context: interaction-flow-execution (from 04_Behavior_and_Communication.md)

```markdown
#### **Key Interaction Flow 3: Workflow & Activity Execution**

**Error Handling (Activity Retries):**

If `job.perform` raises an exception:

1. **Exception raised in job.perform**: Job code raises an error (e.g., `StandardError`)
2. **Activity catches exception**: `AjRunnerActivity.execute` catches the exception in its rescue block
3. **Check if discardable**: Activity calls `RetryMapper.discard_exception?(job_class, exception)` to check if exception matches any `discard_on` declarations
4. **If NOT discardable (retryable exception)**:
   - Activity re-raises the original exception (line 108 in aj_runner_activity.rb: `raise error`)
   - Temporal receives the activity failure
   - Temporal checks the activity's `RetryPolicy` (which was built from the job's `retry_on` configuration):
     - `initial_interval`: wait time before first retry (e.g., 1 second)
     - `backoff_coefficient`: multiplier for subsequent waits (default 2.0)
     - `max_attempts`: maximum retry attempts (e.g., 3)
   - Temporal creates a durable timer for the retry interval
   - After timer fires, Temporal schedules the activity for retry (attempt 2)
   - Activity will be retried up to `max_attempts` times with exponential backoff
5. **If IS discardable (non-retryable exception)**:
   - Activity raises `Temporalio::Activity::ApplicationError.new(error.message, non_retryable: true, cause: error)`
   - Temporal marks activity as Failed (no retry)
   - Workflow fails immediately

**Key Points:**
- Activity retries are managed by Temporal, not by the Ruby code
- Retry state survives worker crashes (durable timers in Temporal)
- Each retry creates a new activity task; job instance is re-created fresh each time
- Workflow history records all activity attempts, failures, and retries
```

### Context: task-i4-t5 (from 02_Iteration_I4.md)

```markdown
*   **Task 4.5: Write Integration Test - Retry Behavior**
    *   **Task ID:** `I4.T5`
    *   **Description:** Write integration test in `spec/integration/retries_spec.rb` that tests retry behavior for transient errors. Test flow: (1) Define a job that fails with `raise StandardError` on first execution, then succeeds on retry (use a counter: `$attempt_count ||= 0; $attempt_count += 1; raise StandardError if $attempt_count == 1; $test_result = 'success'`). (2) Configure job with `retry_on StandardError, wait: 1, attempts: 3`. (3) Enqueue job. (4) Start worker. (5) Wait for job to execute, fail, retry, and succeed. (6) Assert `$test_result == 'success'`. (7) Verify workflow history shows activity retry (check for activity failure + retry events). This test proves retry_on mapping works and Temporal retries activities.
    *   **Acceptance Criteria:**
        - Integration test defines a job that fails once then succeeds
        - Job uses `retry_on StandardError, wait: 1, attempts: 3`
        - Test enqueues job, starts worker
        - Test waits for job to fail, retry, and succeed (max 10 seconds)
        - Test asserts final result is 'success'
        - Test queries workflow history for activity failure + retry events
        - `rake spec:integration` passes for retries_spec.rb
        - Test is isolated
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `spec/integration/enqueue_spec.rb`
    *   **Summary:** This file contains the existing integration test for immediate job execution. It demonstrates the pattern for starting workers, waiting for results, and verifying workflow completion.
    *   **Recommendation:** You MUST use the EXACT SAME test structure and helper methods (`start_worker`, `stop_worker`, `wait_for_result`, `around` block setup). Copy these methods to your new `retries_spec.rb` file to maintain consistency.
    *   **Key Pattern:** Worker is started in a background thread using `Thread.new`, then stopped using `thread.kill` in an ensure block. This ensures cleanup even if test fails.

*   **File:** `spec/integration/scheduled_jobs_spec.rb`
    *   **Summary:** This file shows how to query workflow history to verify specific events (like timer events).
    *   **Recommendation:** You MUST use the pattern `handle.fetch_history` and `history.events.map(&:event_type)` to verify activity retry events.
    *   **Key Code:** Lines 45-47 demonstrate fetching history and checking for timer events:
      ```ruby
      history = handle.fetch_history
      event_types = history.events.map(&:event_type)
      expect(event_types).to include(:EVENT_TYPE_TIMER_STARTED)
      ```

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** This file already contains sample job classes with retry configurations. It includes `RetryableJob` (with `retry_on SampleJobError, wait: 60.seconds, attempts: 5`), `DiscardableJob`, `MultiRetryJob`, etc.
    *   **Recommendation:** You MUST add a NEW job class to this file (e.g., `TransientErrorJob`) that uses `retry_on StandardError, wait: 1, attempts: 3` as specified in the task. DO NOT reuse `TestJob` or `RetryableJob` as they have different configurations.
    *   **Key Pattern:** Jobs inherit from `ActiveJob::Base` (lines 36-72), not from the stub `ApplicationJob` class (lines 10-22).

*   **File:** `lib/activejob/temporal/retry_mapper.rb`
    *   **Summary:** This module translates ActiveJob's `retry_on`/`discard_on` DSL to Temporal's RetryPolicy. It inspects job classes using introspection of rescue_handlers (line 74).
    *   **Recommendation:** Your test job MUST use `ActiveJob::Base` as the parent class and declare `retry_on StandardError, wait: 1, attempts: 3`. The RetryMapper will extract this via introspection.
    *   **Key Method:** `RetryMapper.for(job_class)` (line 10) returns a hash with keys: `:initial_interval`, `:backoff_coefficient`, `:maximum_attempts`, `:non_retryable_error_types`.

*   **File:** `lib/activejob/temporal/activities/aj_runner_activity.rb`
    *   **Summary:** This activity executes the job logic. It catches exceptions (line 72) and checks if they're discardable via `RetryMapper.discard_exception?` (line 100). If NOT discardable, it re-raises the original exception (line 108), which triggers Temporal's retry logic.
    *   **Recommendation:** You DO NOT need to modify this file. The existing error handling will correctly propagate `StandardError` for retry.
    *   **Critical Logic:** Lines 99-109 show the exception handling:
      ```ruby
      def handle_exception(job_class, error)
        if job_class && RetryMapper.discard_exception?(job_class, error)
          raise Temporalio::Activity::ApplicationError.new(...)
        end
        raise error  # <-- Re-raises for retry
      end
      ```

*   **File:** `lib/activejob/temporal/workflows/aj_workflow.rb`
    *   **Summary:** The workflow builds the RetryPolicy by calling `RetryMapper.for(job_class)` (line 56) and passes it to `execute_activity` (line 23-27). The RetryPolicy is converted to `Temporalio::RetryPolicy` object (lines 63-74).
    *   **Recommendation:** You DO NOT need to modify this file. The workflow already handles retry policy mapping correctly.
    *   **Key Method:** `activity_options(payload)` (line 47) builds the activity options including the retry policy.

*   **File:** `spec/support/temporal_test_server.rb`
    *   **Summary:** This helper provides `TemporalTestHelper.client` for accessing the Temporal test server. It configures the "test" namespace and verifies connection.
    *   **Recommendation:** You MUST call `TemporalTestHelper.client` to get the client. The setup is automatic via RSpec hooks (lines 113-121).

### Implementation Tips & Notes

*   **Tip 1 - Job Design:** Create a new job class in `spec/fixtures/sample_jobs.rb` that follows this exact pattern:
    ```ruby
    class TransientErrorJob < ActiveJob::Base
      retry_on StandardError, wait: 1, attempts: 3

      def perform
        $attempt_count ||= 0
        $attempt_count += 1
        raise StandardError, "Transient failure" if $attempt_count == 1
        $test_result = 'success'
      end
    end
    ```
    **Why this works:** Global variables (`$attempt_count`, `$test_result`) persist across job retries because each retry creates a new job instance. Class variables or instance variables would be reset.

*   **Tip 2 - Test Structure:** Follow the EXACT structure from `enqueue_spec.rb`:
    ```ruby
    RSpec.describe "ActiveJob Temporal retries", :integration do
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

      it "retries transient errors" do
        @worker_thread = start_worker
        job = TransientErrorJob.perform_later
        workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

        wait_for_result('success')

        expect($test_result).to eq('success')
        expect($attempt_count).to eq(2)  # Failed once, succeeded once

        # Verify workflow history
        handle = client.workflow_handle(workflow_id)
        description = handle.describe
        expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)

        history = handle.fetch_history
        event_types = history.events.map(&:event_type)
        expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_FAILED)
      end
    end
    ```

*   **Tip 3 - Workflow History Verification:** After the job succeeds, query the workflow history to verify activity retries occurred. Look for these event types:
    - `:EVENT_TYPE_ACTIVITY_TASK_SCHEDULED` - Activity scheduled
    - `:EVENT_TYPE_ACTIVITY_TASK_STARTED` - Activity execution started
    - `:EVENT_TYPE_ACTIVITY_TASK_FAILED` - **This proves a retry occurred**
    - `:EVENT_TYPE_ACTIVITY_TASK_COMPLETED` - Activity eventually succeeded

    You MUST assert that `:EVENT_TYPE_ACTIVITY_TASK_FAILED` appears in the history. This is proof that the activity failed and was retried.

*   **Tip 4 - Timing:** With `wait: 1` second and `backoff_coefficient: 2.0`, the retry timeline is:
    - T+0s: Initial execution (fails)
    - T+1s: First retry (succeeds in your test)
    - Total time: ~1-2 seconds

    Your 10-second timeout is more than sufficient. You can optionally add a timing assertion to verify the retry actually waited.

*   **Tip 5 - Helper Methods:** Copy these helper methods from `enqueue_spec.rb`:
    ```ruby
    def start_worker
      Thread.new do
        worker = Temporalio::Worker.new(
          client: TemporalTestHelper.client,
          task_queue: "default",
          workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
          activities: [ActiveJob::Temporal::Activities::AjRunnerActivity]
        )
        worker.run
      end
    end

    def stop_worker(thread)
      return unless thread&.alive?
      thread.kill
      thread.join(5)
    end

    def wait_for_result(expected)
      Timeout.timeout(10) do
        loop do
          break if $test_result == expected
          sleep 0.1
        end
      end
    end
    ```

*   **Warning 1:** DO NOT use `TestJob` for this test. It has a different purpose (stores result in `TestJob.last_argument`). Create a new job class.

*   **Warning 2:** The job MUST fail only on the first attempt (`if $attempt_count == 1`), not on all attempts. Failing on all attempts would cause the workflow to fail after exhausting retries.

*   **Warning 3:** You MUST reset `$attempt_count` and `$test_result` in BOTH the setup AND the ensure block to guarantee test isolation.

*   **Note:** The `wait: 1` parameter means 1 second (Ruby interprets bare integers as seconds when used with ActiveJob's retry DSL). You can also write `wait: 1.second` for clarity, but `wait: 1` is sufficient.

### Expected Test Flow

1. **Setup:** Reset global variables, configure adapter to `:temporal`
2. **Start Worker:** Launch worker thread polling "default" task queue
3. **Enqueue Job:** Call `TransientErrorJob.perform_later`
4. **First Execution:** Job runs, increments `$attempt_count` to 1, raises `StandardError`
5. **Activity Fails:** Temporal receives activity failure
6. **Temporal Schedules Retry:** Temporal waits 1 second (durable timer), then schedules retry
7. **Second Execution:** Job runs again, increments `$attempt_count` to 2, sets `$test_result = 'success'`
8. **Activity Succeeds:** Temporal marks activity as completed
9. **Workflow Completes:** Temporal marks workflow as completed
10. **Test Assertions:** Verify `$test_result == 'success'`, `$attempt_count == 2`, workflow status is COMPLETED, history contains `:EVENT_TYPE_ACTIVITY_TASK_FAILED`
11. **Cleanup:** Stop worker, reset adapter, reset global variables

### Common Pitfalls to Avoid

1. **Pitfall:** Using instance variables or class variables to track attempts
   - **Why it fails:** Each retry creates a new job instance
   - **Solution:** Use global variables (`$attempt_count`)

2. **Pitfall:** Forgetting to reset global variables in ensure block
   - **Why it fails:** Test pollution; next test sees old values
   - **Solution:** Reset in both setup and ensure blocks

3. **Pitfall:** Making the job fail on every attempt
   - **Why it fails:** Workflow exhausts retries and fails instead of succeeding
   - **Solution:** Fail only when `$attempt_count == 1`

4. **Pitfall:** Not querying workflow history
   - **Why it fails:** Acceptance criteria requires verifying activity failure events
   - **Solution:** Fetch history and assert `:EVENT_TYPE_ACTIVITY_TASK_FAILED` is present

5. **Pitfall:** Using `wait: 60` instead of `wait: 1`
   - **Why it fails:** Test would take 60+ seconds to complete
   - **Solution:** Use `wait: 1` as specified in task description

6. **Pitfall:** Not stopping worker thread
   - **Why it fails:** Resource leak, test interference
   - **Solution:** Always call `stop_worker(@worker_thread)` in ensure block
