# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I4.T4",
  "iteration_id": "I4",
  "iteration_goal": "Implement the Temporal worker bootstrap script, write comprehensive integration tests with a real Temporal test server, and validate end-to-end functionality (enqueue → workflow → activity → job execution).",
  "description": "Write integration test in `spec/integration/scheduled_jobs_spec.rb` that tests scheduled job execution using `set(wait:)`. Test flow: (1) Define test job. (2) Enqueue job with delay: `TestJob.set(wait: 5.seconds).perform_later(42)`. (3) Start worker. (4) Assert job does NOT execute immediately (wait 1 second, verify `$test_result` is still nil). (5) Wait for scheduled time (total 6 seconds from enqueue). (6) Assert job executed after delay. (7) Verify workflow used `Workflow.sleep` (check workflow history for timer event using Temporal test client). This test proves durable scheduled execution works.",
  "agent_type_hint": "BackendAgent",
  "inputs": "RSpec integration test patterns, Temporal test server helper from I4.T2, adapter from I3.T2, workflow sleep logic from I2.T2",
  "target_files": [
    "spec/integration/scheduled_jobs_spec.rb"
  ],
  "input_files": [
    "spec/support/temporal_test_server.rb",
    "lib/activejob/temporal/adapter.rb",
    "lib/activejob/temporal/workflows/aj_workflow.rb",
    "spec/fixtures/sample_jobs.rb"
  ],
  "deliverables": "Passing integration test for scheduled job execution",
  "acceptance_criteria": "Integration test enqueues job with delay: `TestJob.set(wait: 5.seconds).perform_later(42)`; Test starts worker; Test verifies job does NOT execute immediately (check at T+1 second); Test waits for scheduled time (T+6 seconds) and verifies job executed; Test queries workflow history for timer event (proves `Workflow.sleep` was used); Test cleans up; `rake spec:integration` passes for scheduled_jobs_spec.rb; Test is isolated",
  "dependencies": [
    "I3.T2",
    "I2.T2",
    "I4.T2"
  ],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: Scheduled Job Execution Architecture

**Scheduled Execution via `set(wait:)`:**
- When users call `TestJob.set(wait: 5.seconds).perform_later(42)`, ActiveJob invokes `enqueue_at` on the adapter
- The adapter converts the delay into a Unix timestamp and passes it to the payload serializer
- The payload includes a `scheduled_at` field in ISO8601 format
- The workflow is started **immediately** in Temporal, but the `AjWorkflow.execute` method extracts the `scheduled_at` timestamp and calls `Workflow.sleep` for the calculated duration
- This is a **durable sleep** - the workflow doesn't block any worker threads during the sleep
- After the sleep completes, the workflow proceeds to execute the activity

**Key Design Decision:**
The architecture explicitly chose to use `Workflow.sleep` within the workflow rather than Temporal's start delay or Schedules API. This ensures:
1. The workflow is created immediately (supports deduplication via workflow ID)
2. The sleep is durable and survives worker restarts
3. The workflow history includes a timer event that can be verified in tests

### Context: Workflow Sleep Implementation

The `AjWorkflow` class (from `lib/activejob/temporal/workflows/aj_workflow.rb`) includes:

```ruby
def execute(payload)
  scheduled_time = extract_scheduled_time(payload)
  sleep_until(scheduled_time) if scheduled_time

  Temporalio::Workflow.execute_activity(
    AjRunnerActivity,
    payload,
    **activity_options(payload)
  )
end

private

def extract_scheduled_time(payload)
  timestamp = payload[:scheduled_at] || payload["scheduled_at"]
  return unless timestamp

  Time.iso8601(timestamp)
end

def sleep_until(target_time)
  now = Temporalio::Workflow.now
  delay = target_time - now
  return unless delay.positive?

  Temporalio::Workflow.sleep(delay)
end
```

**Critical points:**
- Uses `Temporalio::Workflow.now` (not `Time.now`) for determinism
- Calculates delay as `target_time - now`
- Only sleeps if delay is positive (handles edge cases where scheduled_at is in the past)
- The sleep is deterministic and will be recorded in workflow history as a timer event

### Context: Adapter enqueue_at Method

The adapter's `enqueue_at` method (from `lib/activejob/temporal/adapter.rb`):

```ruby
def enqueue_at(job, timestamp)
  scheduled_time = Time.at(timestamp)
  payload = build_payload(job, scheduled_at: scheduled_time)

  enqueue_with_payload(job, payload)
end
```

**Critical points:**
- Converts Unix timestamp to Time object
- Passes `scheduled_at: scheduled_time` to `Payload.from_job`
- The workflow is started immediately (no delay on Temporal side)

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `spec/integration/enqueue_spec.rb`
    *   **Summary:** This file contains the working integration test for immediate job execution. It provides the complete pattern for worker management, result verification, and workflow status checking.
    *   **Recommendation:** You MUST reuse the test patterns from this file:
        - The `around` block for setup/cleanup
        - The `start_worker` helper method
        - The `stop_worker` helper method
        - The `wait_for_result` polling mechanism
        - Copy these helper methods directly into your new `scheduled_jobs_spec.rb` file

*   **File:** `spec/support/temporal_test_server.rb`
    *   **Summary:** This helper configures the Temporal test client and ensures connection to the test server.
    *   **Recommendation:** You SHOULD use `TemporalTestHelper.client` to get the test client for querying workflow history.

*   **File:** `lib/activejob/temporal/workflows/aj_workflow.rb`
    *   **Summary:** The workflow implementation that handles scheduled execution via `sleep_until`.
    *   **Key Implementation:**
        - Extracts `scheduled_at` from payload
        - Calculates delay using `Temporalio::Workflow.now`
        - Calls `Temporalio::Workflow.sleep(delay)` if delay is positive
        - This sleep is durable and creates a timer event in workflow history
    *   **Recommendation:** You MUST verify that `Workflow.sleep` was called by inspecting the workflow history for a timer event.

*   **File:** `lib/activejob/temporal/adapter.rb`
    *   **Summary:** The adapter with `enqueue_at` method that accepts a Unix timestamp.
    *   **Key Methods:**
        - `enqueue_at(job, timestamp)`: Converts timestamp to Time, adds to payload, starts workflow immediately
        - `build_workflow_id(job)`: Returns deterministic workflow ID in format `"ajwf:#{job.class.name}:#{job.job_id}"`
    *   **Recommendation:** When calling `TestJob.set(wait: 5.seconds).perform_later(42)`, ActiveJob will convert the delay to a timestamp and call `enqueue_at`.

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** Contains `TestJob` class with `last_argument` class variable for result verification.
    *   **Current Implementation:**
        ```ruby
        class TestJob < ActiveJob::Base
          class << self
            attr_accessor :last_argument
          end

          queue_as :default

          def perform(arg)
            self.class.last_argument = arg
          end
        end
        ```
    *   **Recommendation:** You MUST use `TestJob` for the scheduled job test. Reset `TestJob.last_argument = nil` before and after each test.

*   **File:** `lib/activejob/temporal/payload.rb`
    *   **Summary:** Serializes job data including `scheduled_at` in ISO8601 format.
    *   **Recommendation:** The payload handling is already implemented. Focus on verifying the workflow behavior.

### Implementation Tips & Notes

*   **Test Structure Pattern:** Create a new file `spec/integration/scheduled_jobs_spec.rb` following this structure:
    ```ruby
    require "spec_helper"
    require "timeout"
    require "temporalio/worker"
    require_relative "../fixtures/sample_jobs"

    RSpec.describe "ActiveJob Temporal scheduled jobs", :integration do
      let(:client) { TemporalTestHelper.client }

      around do |example|
        original_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :temporal
        TestJob.last_argument = nil

        example.run
      ensure
        ActiveJob::Base.queue_adapter = original_adapter
        stop_worker(@worker_thread)
        TestJob.last_argument = nil
      end

      # Your test case here
    end
    ```

*   **Critical Test Flow:** The test must verify TWO things:
    1. The job does NOT execute immediately (verify at T+1 second)
    2. The job DOES execute after the delay (verify at T+6 seconds)

*   **Timing Implementation:**
    ```ruby
    it "executes a scheduled job after delay" do
      # Start worker FIRST (before enqueue)
      @worker_thread = start_worker

      # Enqueue job with 5 second delay
      job = TestJob.set(wait: 5.seconds).perform_later(42)
      workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

      # Verify job does NOT execute immediately
      sleep 1
      expect(TestJob.last_argument).to be_nil

      # Wait for scheduled execution (remaining ~9 seconds)
      wait_for_result(42)

      # Verify job executed
      expect(TestJob.last_argument).to eq(42)

      # Verify workflow completed with timer event
      # (See workflow history verification below)
    end
    ```

*   **Worker Helper Methods:** Copy these from `enqueue_spec.rb`:
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
          break if TestJob.last_argument == expected
          sleep 0.1
        end
      end
    end
    ```

*   **Workflow History Verification:** After the job completes, query workflow history:
    ```ruby
    description = client.workflow_handle(workflow_id).describe

    # Verify workflow completed
    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)

    # Note: Verifying timer events in workflow history depends on the Temporal Ruby SDK's API
    # If the SDK provides access to history events, you can check for a timer event
    # If not, the timing test (job didn't run immediately) is sufficient proof
    ```

*   **Critical Timing Consideration:**
    - The task specifies `wait: 5.seconds` but you should check at T+1 second and wait until T+6 seconds
    - The actual timing might be slightly longer due to serialization, network latency, and worker polling
    - That's why the test uses a 10-second total timeout in `wait_for_result`

*   **Start Worker BEFORE Enqueue:** This is critical to avoid a race condition. Start the worker first, then enqueue the job.

*   **Test Isolation Requirements:**
    - The test MUST clean up the worker thread in the `ensure` block
    - The test MUST reset `TestJob.last_argument` to nil before and after
    - The test MUST restore the original ActiveJob adapter
    - Use unique job instances to avoid workflow ID conflicts

### Action Required

You need to create a new file `spec/integration/scheduled_jobs_spec.rb` that:
1. Follows the test structure pattern from `enqueue_spec.rb`
2. Enqueues a job with `TestJob.set(wait: 5.seconds).perform_later(42)`
3. Verifies the job does NOT execute immediately (check at T+1 second)
4. Verifies the job DOES execute after the delay (check around T+6 seconds)
5. Queries workflow history to verify completion (timer event verification if SDK supports it)
6. Properly cleans up worker and test state

---

## End of Task Briefing Package

You now have all the information needed to implement the scheduled jobs integration test. Follow the patterns from `enqueue_spec.rb`, verify both timing (no immediate execution) and workflow history (timer event), and ensure proper cleanup.
