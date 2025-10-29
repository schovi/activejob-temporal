# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I4.T7",
  "iteration_id": "I4",
  "iteration_goal": "Implement the Temporal worker bootstrap script, write comprehensive integration tests with a real Temporal test server, and validate end-to-end functionality (enqueue → workflow → activity → job execution).",
  "description": "Write integration test in `spec/integration/cancellation_spec.rb` that tests job cancellation. Test flow: (1) Define a long-running job that calls `Temporalio::Activity.heartbeat` periodically (e.g., `10.times { Temporalio::Activity.heartbeat; sleep 1 }`). (2) Enqueue job. (3) Start worker. (4) Wait for job to start executing (check workflow is running). (5) Call `ActiveJob::Temporal.cancel(TestJob, job_id)`. (6) Wait for workflow to be cancelled (max 5 seconds). (7) Verify workflow status is Cancelled. (8) Verify job did not complete (heartbeat loop interrupted). This test proves cancellation API works and activities can be aborted mid-execution via heartbeating.",
  "agent_type_hint": "BackendAgent",
  "inputs": "RSpec integration test patterns, Temporal test server, cancellation API from I3.T5, activity heartbeat documentation",
  "target_files": [
    "spec/integration/cancellation_spec.rb",
    "spec/fixtures/sample_jobs.rb"
  ],
  "input_files": [
    "spec/support/temporal_test_server.rb",
    "lib/activejob/temporal/cancel.rb",
    "lib/activejob/temporal/workflows/aj_workflow.rb",
    "lib/activejob/temporal/activities/aj_runner_activity.rb",
    "spec/fixtures/sample_jobs.rb"
  ],
  "deliverables": "Passing integration test for cancellation",
  "acceptance_criteria": "Integration test defines a long-running job that heartbeats; Test enqueues job, starts worker; Test waits for workflow to start (query workflow status); Test calls `ActiveJob::Temporal.cancel(LongRunningJob, job_id)`; Test waits for workflow to be cancelled (max 5 seconds); Test verifies workflow status is Cancelled (query via test client); Test verifies job did not complete (heartbeat loop was interrupted, no final result); `rake spec:integration` passes for cancellation_spec.rb; Test is isolated",
  "dependencies": [
    "I3.T5",
    "I2.T3",
    "I4.T2"
  ],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: Job Cancellation Flow (from 04_Behavior_and_Communication.md)

```markdown
#### **Key Interaction Flow 4: Job Cancellation**

**Scenario**: User cancels an in-flight job via `ActiveJob::Temporal.cancel(job_id)`.

**Key Steps:**

1. **User calls cancellation API**: `ActiveJob::Temporal.cancel(job_id)`
2. **Build workflow ID**: Deterministic ID constructed from job class and job_id
3. **Get workflow handle**: Temporal client retrieves handle to running workflow
4. **Send cancellation**: gRPC `RequestCancelWorkflowExecution` call (non-blocking, returns immediately)
5. **Temporal propagates signal**: Sends cancellation to workflow and any running activities
6. **(If activity heartbeats)**: Activity receives `CancelledError`, can abort early
7. **(If no heartbeat)**: Activity completes normally; workflow still marked as cancelled afterward

**Best Practice**: Jobs should call `Temporalio::Activity.heartbeat` periodically (e.g., every 30s) to enable prompt cancellation.
```

**Key Flow Summary:**
- When a job is cancelled via `ActiveJob::Temporal.cancel(job_class, job_id)`, the cancellation API builds the workflow_id and sends a cancellation request
- The cancellation is **best-effort**: it only interrupts activities that call `Temporalio::Activity.heartbeat`
- Jobs must explicitly call `Temporalio::Activity.heartbeat` periodically (e.g., every 1 second in a loop) to enable prompt cancellation
- When heartbeat is called and a cancellation has been requested, Temporal raises a `CancelledError` exception
- The workflow status will eventually be `CANCELLED` regardless of whether the activity heartbeats, but heartbeating allows immediate interruption

### Context: Cancellation Sequence Diagram (from docs/diagrams/cancellation_sequence.puml)

```plantuml
alt Activity heartbeating
  Worker -> Activity: cancellation requested (signal)
  Activity -> Temporal: Temporalio::Activity.heartbeat(details)
  Temporal --> Activity: raises CancelledError
  Activity -> Worker: abort job.perform and cleanup
  Worker -> Temporal: report ActivityCancelled
  Temporal --> Client: cancellation acknowledged
else Activity not heartbeating
  note right of Activity: Without heartbeat the activity may finish even after cancel signal
  Activity --> Worker: completes work as normal
  Worker -> Temporal: ActivityCompleted
  Temporal -> Worker: workflow marked Cancelled after completion
end

note over Activity, Temporal: Best-effort cancellation relies on jobs heartbeating periodically for prompt handling
```

**Key Insight:**
- The test MUST have two paths: one where the activity heartbeats (and gets interrupted), and one where it doesn't (and completes normally)
- For this task, we're testing the **heartbeating path** where cancellation interrupts the job mid-execution
- The diagram shows that when `Temporalio::Activity.heartbeat` is called, it will raise a `CancelledError` if cancellation was requested
- This exception should propagate out of the job's perform method, causing the activity to fail with cancellation

### Context: Cancellation API Implementation (from lib/activejob/temporal/cancel.rb)

```ruby
# Cancels a running Temporal workflow by sending a cancellation request.
# This is a best-effort operation; if the workflow already completed or
# does not exist, the error is logged and suppressed.
#
# @param job_class [Class] The ActiveJob class for the job to cancel.
# @param job_id [String] Identifier of the job to cancel.
#
# @example Cancel a running job
#   ActiveJob::Temporal.cancel(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
def cancel(job_class, job_id)
  workflow_id = build_workflow_id(job_class, job_id)
  ActiveJob::Temporal.client.workflow_handle(workflow_id).cancel
  log_cancellation_requested(job_class, job_id, workflow_id)
rescue StandardError => e
  return log_workflow_not_found(job_class, job_id, workflow_id, e) if workflow_not_found?(e)

  raise
end

private

def build_workflow_id(job_class, job_id)
  "ajwf:#{job_class.name}:#{job_id}"
end
```

**Key Details:**
- The cancellation API requires **both** `job_class` and `job_id` parameters (not just job_id)
- It constructs the workflow_id using the format `"ajwf:#{job_class.name}:#{job_id}"`
- The cancel method is best-effort and returns gracefully if the workflow is not found
- In your test, you MUST call: `ActiveJob::Temporal.cancel(LongRunningJob, job.job_id)`

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal/cancel.rb`
    *   **Summary:** This file implements the cancellation API that your test will invoke. The `cancel(job_class, job_id)` method sends a cancellation request to Temporal.
    *   **Recommendation:** You MUST use the correct signature: `ActiveJob::Temporal.cancel(LongRunningJob, job.job_id)` (with job class, not just job_id).
    *   **Critical Detail:** The cancel method is synchronous but **non-blocking** - it returns immediately after sending the cancellation request. You need to wait asynchronously for the workflow to actually reach the CANCELLED state.

*   **File:** `lib/activejob/temporal/activities/aj_runner_activity.rb`
    *   **Summary:** This file contains the activity that executes ActiveJob jobs. It does NOT currently include any heartbeat logic.
    *   **Critical Finding:** The activity's `execute` method (lines 63-76) directly calls `job.perform(*args)` without any heartbeat mechanism. This means:
        1. For cancellation to work, the **job itself** must call `Temporalio::Activity.heartbeat` inside its `perform` method
        2. You cannot rely on the activity wrapper to heartbeat automatically
    *   **Recommendation:** Your test job's `perform` method MUST explicitly call `Temporalio::Activity.heartbeat` in a loop. Example:
        ```ruby
        def perform
          10.times do
            Temporalio::Activity.heartbeat
            sleep 1
            $long_running_iterations += 1
          end
          $long_running_completed = true
        end
        ```

*   **File:** `spec/integration/retries_spec.rb`
    *   **Summary:** This is the existing integration test file for retry behavior. It demonstrates the standard test pattern you should follow.
    *   **Recommendation:** Follow the exact same structure: use `around` block for setup/teardown (lines 12-26), start a worker with a unique task queue (line 30), enqueue job (line 34), wait for workflow state change, verify workflow status, check workflow history.
    *   **Critical Pattern:** The test uses global variables (`$attempt_count`, `$test_result`) to track execution state. For your test, you should use similar global variables like `$long_running_iterations` and `$long_running_completed` to verify the job was interrupted mid-execution.

*   **File:** `spec/integration/enqueue_spec.rb`
    *   **Summary:** This file shows the basic worker setup and workflow status checking patterns.
    *   **Recommendation:** Copy the `start_worker` and `stop_worker` helper methods (lines 41-58). These are the same pattern used in retries_spec.rb.

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** This file contains sample job classes for testing. It currently has NO long-running job that heartbeats.
    *   **Recommendation:** You MUST create a new job class called `LongRunningJob` (or similar) at the end of this file. It should:
        1. Inherit from `ActiveJob::Base`
        2. Have a `queue_as :default` declaration
        3. Implement a `perform` method that loops 10 times, calling `Temporalio::Activity.heartbeat` and `sleep 1` on each iteration
        4. Set global variables to track progress: `$long_running_iterations` (counter) and `$long_running_completed` (boolean flag)
    *   **Example Pattern:**
        ```ruby
        class LongRunningJob < ActiveJob::Base
          queue_as :default

          def perform
            $long_running_iterations = 0
            10.times do
              Temporalio::Activity.heartbeat
              sleep 1
              $long_running_iterations += 1
            end
            $long_running_completed = true
          end
        end
        ```

*   **File:** `spec/support/temporal_test_server.rb`
    *   **Summary:** Helper module that manages Temporal test server connection for integration tests. Provides `TemporalTestHelper.client` method.
    *   **Recommendation:** You MUST use `TemporalTestHelper.client` to get the Temporal client for querying workflow status. This is already done correctly in the existing tests.

### Implementation Tips & Notes

*   **Tip #1: Workflow Status Polling**
    Your test needs to wait for the workflow to reach the `CANCELLED` state. Create a helper method similar to `wait_for_workflow_completion` from retries_spec.rb but check for CANCELLED status:
    ```ruby
    def wait_for_workflow_cancellation(workflow_id)
      Timeout.timeout(5) do
        loop do
          handle = client.workflow_handle(workflow_id)
          description = handle.describe
          status = description.status
          break if status == Temporalio::Client::WorkflowExecutionStatus::CANCELLED ||
                   status == Temporalio::Client::WorkflowExecutionStatus::COMPLETED

          sleep 0.1
        end
      end
    end
    ```

*   **Tip #2: Wait for Workflow to Start**
    Before calling cancel, you need to ensure the workflow has actually started and the activity is executing. Use a helper to poll until the workflow status is RUNNING:
    ```ruby
    def wait_for_workflow_running(workflow_id)
      Timeout.timeout(5) do
        loop do
          handle = client.workflow_handle(workflow_id)
          description = handle.describe
          break if description.status == Temporalio::Client::WorkflowExecutionStatus::RUNNING

          sleep 0.1
        end
      end
    end
    ```

*   **Tip #3: Verify Job Was Interrupted**
    After cancellation, verify the job did NOT complete by checking the global variables:
    ```ruby
    expect($long_running_completed).to eq(false)  # Job should NOT have completed
    expect($long_running_iterations).to be < 10   # Job should have been interrupted mid-loop
    expect($long_running_iterations).to be > 0    # Job should have started (at least 1 iteration)
    ```

*   **Tip #4: Test Timing**
    The test flow should be:
    1. Enqueue job
    2. Start worker
    3. Wait for workflow to reach RUNNING status (~1-2 seconds)
    4. Call cancel
    5. Wait for workflow to reach CANCELLED status (~1-3 seconds)
    6. Verify status and incomplete execution

    Total timeout should be ~5 seconds, as specified in acceptance criteria.

*   **Tip #5: Global Variable Management**
    Initialize and reset the global variables in the `around` block:
    ```ruby
    around do |example|
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :temporal
      $long_running_iterations = 0
      $long_running_completed = false

      example.run
    ensure
      ActiveJob::Base.queue_adapter = original_adapter
      stop_worker(@worker_thread)
      $long_running_iterations = 0
      $long_running_completed = false
    end
    ```

*   **Tip #6: Workflow History Verification (Optional Enhancement)**
    While not strictly required by acceptance criteria, you may want to verify the workflow history shows activity cancellation:
    ```ruby
    history = handle.fetch_history
    event_types = history.events.map(&:event_type)
    expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_SCHEDULED)
    expect(event_types).to include(:EVENT_TYPE_ACTIVITY_TASK_STARTED)
    # May include EVENT_TYPE_ACTIVITY_TASK_CANCELED or similar
    expect(event_types).to include(:EVENT_TYPE_WORKFLOW_EXECUTION_CANCELED)
    ```

*   **Warning: Heartbeat API Availability**
    The `Temporalio::Activity.heartbeat` method is only available when code is running inside a real Temporal activity context. In unit tests with stubs, this would fail. However, since this is an integration test with a real Temporal test server and worker, the heartbeat API should be available. If you encounter issues, verify:
    1. The worker is actually running (check thread is alive)
    2. The activity is executing on the worker (not in the main test thread)

*   **Warning: Exception Handling in Job**
    The job's perform method should NOT catch the `Temporalio::Activity::CancelledError` exception (or whatever exception Temporal raises on heartbeat). Let it propagate naturally so the activity reports cancellation back to Temporal. If you catch and suppress it, the job will complete normally instead of being cancelled.

*   **Note: Task Queue Isolation**
    Like the retry test, use a unique task queue for each test run to avoid interference:
    ```ruby
    task_queue = "cancel-test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    job = LongRunningJob.set(queue: task_queue).perform_later
    ```

### Test Structure Recommendation

Based on the existing retry test and cancellation requirements, your test should follow this structure:

```ruby
RSpec.describe "ActiveJob Temporal cancellation", :integration do
  let(:client) { TemporalTestHelper.client }

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal
    $long_running_iterations = 0
    $long_running_completed = false

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    stop_worker(@worker_thread)
    $long_running_iterations = 0
    $long_running_completed = false
  end

  it "cancels a long-running job via heartbeat mechanism" do
    task_queue = "cancel-test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5  # Give worker time to start

    job = LongRunningJob.set(queue: task_queue).perform_later
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

    # Wait for workflow to start executing
    wait_for_workflow_running(workflow_id)

    # Cancel the job
    ActiveJob::Temporal.cancel(LongRunningJob, job.job_id)

    # Wait for workflow to be cancelled
    wait_for_workflow_cancellation(workflow_id)

    # Verify workflow status is CANCELLED
    handle = client.workflow_handle(workflow_id)
    description = handle.describe
    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::CANCELLED)

    # Verify job did not complete (heartbeat loop was interrupted)
    expect($long_running_completed).to eq(false)
    expect($long_running_iterations).to be < 10  # Interrupted before 10 iterations
    expect($long_running_iterations).to be > 0   # But started (at least 1 iteration)
  end

  private

  def start_worker(task_queue)
    @worker = Temporalio::Worker.new(
      client: TemporalTestHelper.client,
      task_queue: task_queue,
      workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
      activities: [ActiveJob::Temporal::Activities::AjRunnerActivity]
    )

    Thread.new { @worker.run }
  end

  def stop_worker(thread)
    return unless thread&.alive?

    thread.kill
    thread.join(5)
  end

  def wait_for_workflow_running(workflow_id)
    Timeout.timeout(5) do
      loop do
        handle = client.workflow_handle(workflow_id)
        description = handle.describe
        break if description.status == Temporalio::Client::WorkflowExecutionStatus::RUNNING

        sleep 0.1
      end
    end
  end

  def wait_for_workflow_cancellation(workflow_id)
    Timeout.timeout(5) do
      loop do
        handle = client.workflow_handle(workflow_id)
        description = handle.describe
        status = description.status
        break if status == Temporalio::Client::WorkflowExecutionStatus::CANCELLED

        sleep 0.1
      end
    end
  end
end
```

---

## Summary

You are implementing Task I4.T7: an integration test for job cancellation that proves the cancellation API works and activities can be aborted mid-execution via heartbeating. The test MUST:
1. **Create a new LongRunningJob** in `spec/fixtures/sample_jobs.rb` that loops 10 times, calling `Temporalio::Activity.heartbeat` and `sleep 1` on each iteration
2. **Create a new test file** `spec/integration/cancellation_spec.rb` with the cancellation test
3. **Enqueue the job** and start a worker
4. **Wait for the workflow to start** executing (status = RUNNING)
5. **Call the cancel API**: `ActiveJob::Temporal.cancel(LongRunningJob, job.job_id)`
6. **Wait for cancellation** (workflow status becomes CANCELLED)
7. **Verify the job was interrupted** mid-execution (global variable shows < 10 iterations, and completed flag is false)

The key insight is that cancellation is **best-effort** and relies on the job explicitly calling `Temporalio::Activity.heartbeat`. Without heartbeat calls, the cancellation signal is ignored until the activity completes. Your test proves that WITH heartbeating, cancellation interrupts the job promptly.

All necessary infrastructure (test server helper, worker setup, cancel API) is already in place. You are creating TWO new files: the test file and adding a new job class to sample_jobs.rb.
