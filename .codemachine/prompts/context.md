# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I4.T3",
  "iteration_id": "I4",
  "iteration_goal": "Implement the Temporal worker bootstrap script, write comprehensive integration tests with a real Temporal test server, and validate end-to-end functionality (enqueue → workflow → activity → job execution).",
  "description": "Write integration test in `spec/integration/enqueue_spec.rb` that tests end-to-end immediate job execution (no scheduling). Test flow: (1) Define a simple test job (e.g., `class TestJob < ApplicationJob; def perform(arg); $test_result = arg; end; end`). (2) Configure ActiveJob to use TemporalAdapter (in test setup). (3) Enqueue job: `TestJob.perform_later(42)`. (4) Start a Temporal worker in a background thread (or subprocess) polling the \"default\" task queue. (5) Wait for job to execute (poll `$test_result` or use a more robust mechanism like condition variables or test helper). (6) Assert `$test_result == 42`. (7) Verify workflow completed in Temporal (query workflow history using test client). (8) Clean up: stop worker, reset state. Use Temporal test server from I4.T2. This is a full end-to-end test proving enqueue → workflow → activity → job execution works.",
  "agent_type_hint": "BackendAgent",
  "inputs": "RSpec integration test patterns, Temporal test server helper from I4.T2, adapter from I3.T1, workflow/activity from I2.T2/I2.T3, worker bootstrap logic from I4.T1",
  "target_files": [
    "spec/integration/enqueue_spec.rb",
    "spec/fixtures/sample_jobs.rb"
  ],
  "input_files": [
    "spec/support/temporal_test_server.rb",
    "lib/activejob/temporal/adapter.rb",
    "lib/activejob/temporal/workflows/aj_workflow.rb",
    "lib/activejob/temporal/activities/aj_runner_activity.rb",
    "spec/fixtures/sample_jobs.rb"
  ],
  "deliverables": "Passing integration test for immediate job execution",
  "acceptance_criteria": "Integration test defines a simple ActiveJob job (TestJob); Test configures ActiveJob adapter to TemporalAdapter; Test enqueues job: `TestJob.perform_later(42)`; Test starts a worker in background (thread or subprocess) polling task queue; Test waits for job execution (max 10 seconds timeout); Test asserts job executed with correct argument (`$test_result == 42` or similar); Test queries Temporal for workflow completion (using test client); Test cleans up: stops worker, resets state; `rake spec:integration` (or `rake spec`) passes for enqueue_spec.rb (immediate execution test); Test is isolated (can run multiple times without interference)",
  "dependencies": ["I3.T1", "I2.T2", "I2.T3", "I4.T2"],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: Interaction Flow Enqueue (from 04_Behavior_and_Communication.md)

```markdown
#### **Key Interaction Flow 1: Job Enqueue (Immediate Execution)**

**Scenario**: Rails application enqueues a job for immediate execution via `perform_later`.

**Key Steps:**

1. **Developer calls** `SendInvoiceJob.perform_later(42)` in Rails
2. **ActiveJob creates job instance** with UUID job_id and arguments [42]
3. **Adapter.enqueue(job)** is invoked
4. **Payload Serializer** creates JSON payload: `{job_class: "SendInvoiceJob", job_id: "...", arguments: [42], ...}`
5. **Retry Mapper** extracts retry policy from job class (retry_on/discard_on declarations)
6. **Search Attributes Builder** creates metadata: `{ajClass: "SendInvoiceJob", ajQueue: "billing", ajJobId: "...", ajEnqueuedAt: Time.now}`
7. **Client.start_workflow** calls Temporal gRPC API with:
   - workflow_id: `"ajwf:SendInvoiceJob:#{job_id}"`
   - task_queue: resolved from job.queue_name (with optional prefix)
   - id_conflict_policy: `:reject` (prevents duplicate workflows)
   - search_attributes: metadata for visibility
8. **Temporal Cluster** creates workflow, returns workflow_run handle
9. **Adapter logs** "workflow_enqueued" event
10. **Error Handling**: If Temporal unreachable, raises `ActiveJob::EnqueueError`
```

### Context: Workflow & Activity Execution Flow (from 04_Behavior_and_Communication.md)

```markdown
#### **Key Interaction Flow 3: Workflow & Activity Execution**

**Scenario**: A Temporal worker picks up the workflow task, executes the workflow logic, then executes the activity (actual job).

**Key Steps:**

1. **Worker polls for workflow task**: Long-poll request to Temporal, receives workflow task
2. **Workflow execution begins**: Worker invokes `AjWorkflow.execute(payload)`
3. **(Optional) Sleep**: If `scheduled_at` is set and in the future, workflow calls `Workflow.sleep`
   - **Crucially**: Worker thread is **not blocked**; it returns to poll for other tasks
   - Temporal persists a timer event in workflow history
4. **Workflow schedules activity**: Calls `execute_activity(AjRunnerActivity, payload, ...)`
5. **Workflow task completes**: Worker reports back to Temporal; workflow enters "Waiting for activity" state
6. **Worker polls for activity task**: Receives activity task from Temporal
7. **Activity execution begins**: Worker invokes `AjRunnerActivity.execute(payload)`
8. **Payload deserialization**: Converts JSON payload back to Ruby job arguments
9. **Idempotency key set**: Stores workflow/activity identifiers in `Thread.current` (app code can read this)
10. **Job instantiation & execution**: Creates job instance, calls `job.perform(args)`
11. **Job logic runs**: Makes external API calls, database writes, etc.
12. **Activity completes**: Returns to worker, which reports success to Temporal
13. **Workflow completes**: Temporal marks workflow as `Completed`, archives to history

**Error Handling**: If `job.perform` raises an exception, the activity checks if it matches `discard_on` declarations. If yes, wraps in `Temporalio::Activity::ApplicationError(non_retryable: true)`. Otherwise, re-raises for Temporal's retry mechanism.
```

### Context: Task I4.T3 Description (from 02_Iteration_I4.md)

```markdown
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
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `spec/integration/enqueue_spec.rb`
    *   **Summary:** This file ALREADY EXISTS and implements the exact test described in task I4.T3. The integration test for immediate job execution is complete with all required functionality.
    *   **Current Implementation:**
        - Defines a complete test case "executes an enqueued job immediately via Temporal"
        - Uses `TestJob.perform_later(42)` to enqueue a job
        - Starts a worker in a background thread using `start_worker` helper
        - Waits for job execution with `wait_for_result(42)` using a timeout-based polling mechanism
        - Asserts `TestJob.last_argument == 42` to verify job executed
        - Queries workflow status using `client.workflow_handle(workflow_id).describe`
        - Verifies workflow completion with `expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)`
        - Cleans up worker properly in `around` block and `ensure` clause
    *   **Recommendation:** **THE TASK IS ALREADY COMPLETE**. The file at `spec/integration/enqueue_spec.rb` already implements all the acceptance criteria specified in task I4.T3.

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** Contains job fixtures including `TestJob` which is used by the integration test.
    *   **Current Implementation:**
        - `TestJob` is defined at lines 74-84 as an `ActiveJob::Base` subclass
        - Uses a class variable `TestJob.last_argument` instead of a global `$test_result`
        - Has `queue_as :default` declaration
        - Implements `perform(arg)` method that sets `self.class.last_argument = arg`
    *   **Recommendation:** The `TestJob` is already properly implemented. The integration test uses this job class correctly.

*   **File:** `spec/support/temporal_test_server.rb`
    *   **Summary:** Provides helper methods for setting up and managing the Temporal test server connection for integration tests.
    *   **Key Features:**
        - `TemporalTestHelper.client` method that returns a configured Temporal client
        - Automatic setup/teardown via RSpec hooks (`before(:suite)` and `after(:suite)`)
        - Connection verification to ensure Temporal server is available
        - Clear error messages if test server is not running
        - Configuration management (stores/restores original config)
    *   **Recommendation:** The integration test correctly uses `TemporalTestHelper.client` to get the test client.

*   **File:** `lib/activejob/temporal/adapter.rb`
    *   **Summary:** Implements the `TemporalAdapter` that bridges ActiveJob and Temporal.
    *   **Key Methods:**
        - `enqueue(job)`: Serializes payload, builds workflow_id, resolves task_queue, starts workflow
        - `build_workflow_id(job)`: Returns deterministic workflow ID in format `"ajwf:#{job.class.name}:#{job.job_id}"`
        - `resolve_task_queue(job)`: Returns task queue name (with optional prefix)
        - Error handling for duplicate workflows (logs but doesn't raise)
    *   **Recommendation:** The integration test correctly uses `ActiveJob::Temporal::Adapter.build_workflow_id(job)` to get the workflow_id for verification.

*   **File:** `lib/activejob/temporal/workflows/aj_workflow.rb`
    *   **Summary:** Implements the deterministic workflow that orchestrates job execution.
    *   **Key Logic:**
        - `execute(payload)`: Main workflow method
        - Extracts `scheduled_at` from payload and sleeps if present
        - Calls `execute_activity(AjRunnerActivity, payload, **activity_options)`
        - Passes retry policy from payload to activity options
    *   **Recommendation:** The workflow is registered correctly in the worker thread created by `start_worker` helper.

*   **File:** `lib/activejob/temporal/activities/aj_runner_activity.rb`
    *   **Summary:** Implements the activity that deserializes and executes the actual job.
    *   **Key Logic:**
        - `execute(payload)`: Deserializes arguments, constantizes job class, instantiates job, calls perform
        - Sets idempotency key in `Thread.current`
        - Handles exceptions: wraps discard_on errors in `ApplicationError(non_retryable: true)`
    *   **Recommendation:** The activity is registered correctly in the worker thread created by `start_worker` helper.

### Implementation Tips & Notes

*   **Critical Finding:** The integration test file `spec/integration/enqueue_spec.rb` **ALREADY EXISTS** and fully implements task I4.T3. The test includes:
    1. ✅ TestJob definition (in sample_jobs.rb)
    2. ✅ ActiveJob adapter configuration (in `around` block)
    3. ✅ Job enqueue (`TestJob.perform_later(42)`)
    4. ✅ Worker started in background thread
    5. ✅ Wait for job execution with timeout (10 seconds via `Timeout.timeout(10)`)
    6. ✅ Assertion that job executed correctly (`expect(TestJob.last_argument).to eq(42)`)
    7. ✅ Workflow completion verification (`expect(description.status).to eq(...::COMPLETED)`)
    8. ✅ Proper cleanup (worker stopped in `around` block's `ensure` clause)

*   **Test Isolation:** The test uses an `around` block to:
    - Save original adapter: `original_adapter = ActiveJob::Base.queue_adapter`
    - Set Temporal adapter: `ActiveJob::Base.queue_adapter = :temporal`
    - Reset test state: `TestJob.last_argument = nil`
    - Clean up: `ActiveJob::Base.queue_adapter = original_adapter` and `stop_worker(@worker_thread)`

*   **Worker Management:** The test uses a thread-based worker (not subprocess):
    - `start_worker` creates a new thread that runs `Temporalio::Worker.new(...).run`
    - Worker is configured with correct task_queue ("default"), workflows, and activities
    - `stop_worker` kills the thread with `thread.kill` and waits for it to join (5 second timeout)

*   **Result Verification:** Instead of using a global `$test_result`, the implementation uses:
    - Class attribute: `TestJob.last_argument` (cleaner and thread-safe for test isolation)
    - Polling loop: `wait_for_result(expected)` polls until `TestJob.last_argument == expected`
    - Timeout protection: Wrapped in `Timeout.timeout(10)` to prevent hanging tests

*   **Workflow Query:** The test correctly:
    - Builds workflow_id using the adapter helper
    - Gets workflow handle: `client.workflow_handle(workflow_id)`
    - Calls `describe` method to get workflow description
    - Checks status: `description.status == Temporalio::Client::WorkflowExecutionStatus::COMPLETED`

*   **Test Tag:** The test is marked with `:integration` tag (`RSpec.describe "...", :integration`), which allows running integration tests separately from unit tests.

### Action Required

**NO CODE CHANGES ARE NEEDED.** This task (I4.T3) has already been completed. The integration test exists, is properly implemented, and meets all acceptance criteria specified in the task description.

To verify the test works:
1. Ensure a Temporal test server is running: `temporal server start-dev --namespace test`
2. Run the integration test: `bundle exec rspec spec/integration/enqueue_spec.rb`

The task can be marked as `"done": true` in the tasks manifest.
