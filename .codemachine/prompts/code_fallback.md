# Code Refinement Task

The previous code submission did not pass verification. You must fix the following issues and resubmit your work.

---

## Original Task Description

Write integration test in `spec/integration/retries_spec.rb` that tests retry behavior for transient errors. Test flow: (1) Define a job that fails with `raise StandardError` on first execution, then succeeds on retry (use a counter: `$attempt_count ||= 0; $attempt_count += 1; raise StandardError if $attempt_count == 1; $test_result = 'success'`). (2) Configure job with `retry_on StandardError, wait: 1, attempts: 3`. (3) Enqueue job. (4) Start worker. (5) Wait for job to execute, fail, retry, and succeed. (6) Assert `$test_result == 'success'`. (7) Verify workflow history shows activity retry (check for activity failure + retry events). This test proves retry_on mapping works and Temporal retries activities.

---

## Issues Detected

*   **Critical: Missing Activity Failure Verification:** The test does NOT verify that activity failure events appear in the workflow history. Lines 51-53 only check for `:EVENT_TYPE_ACTIVITY_TASK_SCHEDULED` and `:EVENT_TYPE_ACTIVITY_TASK_COMPLETED`, but the acceptance criteria explicitly requires: "Test queries workflow history for activity failure + retry events".

---

## Best Approach to Fix

You MUST modify `spec/integration/retries_spec.rb` to add verification for activity failure events in the workflow history. Replace lines 44-53 with the following code:

```ruby
    # Verify workflow history shows activity retry
    history = handle.fetch_history
    event_types = history.events.map(&:event_type)

    # Verify activity was scheduled
    expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_SCHEDULED)

    # CRITICAL: Verify activity failed (proves retry occurred)
    expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_FAILED)

    # Verify activity eventually completed
    expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_COMPLETED)
```

**Rationale:** The presence of `:EVENT_TYPE_ACTIVITY_TASK_FAILED` in the workflow history is PROOF that the activity failed and was retried by Temporal. This is the core requirement of the acceptance criteria: "Test queries workflow history for activity failure + retry events."

---

## What NOT to Change

- DO NOT modify the job class `RetryTestJob` - it is correct
- DO NOT modify the test setup, worker start/stop, or wait logic - they are correct
- DO NOT modify the assertions for `$test_result` or `$attempt_count` - they are correct
- ONLY change the workflow history verification section (lines 44-53)
