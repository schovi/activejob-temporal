# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I6.T3",
  "iteration_id": "I6",
  "iteration_goal": "Enhance Version 2 with robust validation, better error handling, and comprehensive documentation from Version 1 analysis while maintaining Version 2's superior architecture.",
  "description": "Enhance the Cancel module in `lib/activejob/temporal/cancel.rb` with better error handling to distinguish between workflows that never existed vs workflows that already completed. Add custom exception classes `WorkflowNotFoundError` and `TemporalConnectionError` to `lib/activejob/temporal.rb`. Refactor the `cancel` method to: (1) Add a private `find_workflow(client, job_class, job_id)` method that queries Temporal with `list_workflows` for running workflows matching the job_id search attribute; (2) If not found in running workflows, query closed workflows (with ExecutionStatus IN ('Completed', 'Failed', 'Cancelled', etc.)); (3) If found in closed workflows, return `false` from `cancel` method to indicate job already completed (log this with Logger.warn); (4) If not found in either running or closed workflows, raise `WorkflowNotFoundError` with message 'No workflow found for job_id X. The job may have never existed.'; (5) Wrap Temporal client calls in rescue blocks to catch connection errors and raise `TemporalConnectionError` with descriptive messages. Update existing unit tests in `spec/unit/cancel_spec.rb` to cover new scenarios: workflow completed (returns false), workflow never existed (raises WorkflowNotFoundError), Temporal connection failure (raises TemporalConnectionError). Add integration test in `spec/integration/cancellation_spec.rb` if not already present.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Version 1 lib/active_job/temporal/cancel.rb:1-138 (enhanced error handling pattern), Version 2 existing cancel.rb, Temporal list_workflows API documentation",
  "target_files": [
    "lib/activejob/temporal.rb",
    "lib/activejob/temporal/cancel.rb",
    "spec/unit/cancel_spec.rb",
    "spec/integration/cancellation_spec.rb"
  ],
  "input_files": [
    "lib/activejob/temporal.rb",
    "lib/activejob/temporal/cancel.rb",
    "spec/unit/cancel_spec.rb",
    "spec/integration/cancellation_spec.rb"
  ],
  "deliverables": "Enhanced Cancel module with better error handling, new exception types, comprehensive tests",
  "acceptance_criteria": "ActiveJob::Temporal::WorkflowNotFoundError exception class exists; ActiveJob::Temporal::TemporalConnectionError exception class exists; Cancel.cancel method returns false if workflow already completed (without raising); Cancel.cancel method raises WorkflowNotFoundError if workflow never existed; Cancel.cancel method raises TemporalConnectionError if Temporal client connection fails; Private find_workflow method queries both running and closed workflows; Unit tests in cancel_spec.rb cover: successful cancellation, workflow completed (returns false), workflow not found (raises WorkflowNotFoundError), connection error (raises TemporalConnectionError); Integration test verifies cancellation behavior end-to-end (if applicable); Structured logging uses Logger.warn for completed workflows, Logger.info for successful cancellation requests; `rake spec` passes; `rake rubocop` passes",
  "dependencies": [
    "I6.T1"
  ],
  "parallelizable": true,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: interaction-flow-cancellation (from 04_Behavior_and_Communication.md)

```markdown
<!-- anchor: interaction-flow-cancellation -->
#### **Key Interaction Flow 4: Job Cancellation**

**Scenario**: User cancels an in-flight job via `ActiveJob::Temporal.cancel(job_id)`.

**Diagram:**

~~~plantuml
@startuml
actor "Developer/Admin" as Dev
participant "Rails App" as Rails
participant "Cancellation API" as Cancel
participant "Temporal Client" as Client
participant "Temporal Cluster" as Temporal
participant "Worker" as Worker
participant "AjRunnerActivity" as Activity

Dev -> Rails : ActiveJob::Temporal.cancel("job-uuid-123")
Rails -> Cancel : cancel("job-uuid-123")
activate Cancel

Cancel -> Cancel : workflow_id = "ajwf:SendInvoiceJob:job-uuid-123"
Cancel -> Client : handle = client.get_workflow_handle(workflow_id)
Client -> Temporal : gRPC GetWorkflowExecutionHistory (brief check)
Temporal --> Client : Workflow exists, status: Running

Cancel -> Client : handle.cancel
Client -> Temporal : gRPC RequestCancelWorkflowExecution
Temporal --> Client : Cancellation requested

Cancel --> Rails : (void, returns immediately)
deactivate Cancel

note right of Temporal
  Cancellation signal sent,
  but activity may not abort instantly
end note

Temporal -> Worker : Deliver cancellation signal (if activity is running)

alt Activity is heartbeating
  Worker -> Activity : Temporalio::Activity.heartbeat
  Activity -> Temporal : Heartbeat RPC
  Temporal --> Activity : CancelledError (exception)
  Activity -> Activity : Catch CancelledError, cleanup, re-raise
  Activity --> Worker : Activity cancelled
  Worker -> Temporal : Report activity cancelled
  Temporal -> Temporal : Mark workflow as Cancelled
else Activity is NOT heartbeating
  note right of Activity
    Activity continues to completion
    Cancellation only takes effect
    after activity finishes
  end note
  Activity --> Worker : Activity completes normally
  Worker -> Temporal : Activity complete
  Temporal -> Temporal : Workflow still receives cancellation,\n  completes with Cancelled status
end

@enduml
~~~

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

### Context: communication-error-handling (from 04_Behavior_and_Communication.md)

```markdown
<!-- anchor: communication-error-handling -->
#### **Communication Error Handling**

**Enqueue-Time Errors:**

| Error Scenario | Exception Raised | Handling |
|----------------|------------------|----------|
| Temporal cluster unreachable | `ActiveJob::EnqueueError` | Rails rescues, may retry or log |
| Payload too large (>250KB) | `ActiveJob::SerializationError` | Rails rescues, job not enqueued |
| Invalid arguments (non-serializable) | `ActiveJob::SerializationError` | Rails rescues, job not enqueued |
| Workflow ID collision (duplicate `job_id`) | `Temporalio::Client::WorkflowAlreadyStartedError` | Silently ignored (idempotent enqueue) |

**Execution-Time Errors:**

| Error Scenario | Handling | Outcome |
|----------------|----------|---------|
| Activity timeout (>15min) | Temporal raises `Temporalio::Activity::TimeoutError` | Activity fails, workflow retries per `RetryPolicy` |
| Worker crash during activity | Temporal detects heartbeat timeout | Activity scheduled on another worker |
| Exception in `job.perform` | Caught by `AjRunnerActivity`, mapped to `ApplicationError` | Retried per `retry_on` or marked non-retryable per `discard_on` |
| Workflow code bug (non-determinism) | Temporal raises `Temporalio::Workflow::NondeterminismError` | Workflow stuck, requires code fix + reset |

**Communication Timeouts:**

- **gRPC call timeout**: 10s default (configurable via `temporalio`)
- **Activity start-to-close timeout**: 15 minutes default (configurable)
- **Workflow execution timeout**: None (workflows can run indefinitely if sleeping)
```

### Context: workflow-metadata (from 03_System_Structure_and_Data.md)

```markdown
**2. Workflow Metadata (Temporal Search Attributes)**

Attached to the workflow on start, enabling queries in Temporal UI.

| Attribute | Type | Purpose | Example |
|-----------|------|---------|---------|
| `ajClass` | Keyword | Job class name for filtering | `"SendInvoiceJob"` |
| `ajQueue` | Keyword | Task queue/job queue | `"billing"` |
| `ajJobId` | Keyword | ActiveJob job_id for correlation | `"a1b2c3d4-..."` |
| `ajEnqueuedAt` | Datetime | Enqueue timestamp | `2025-10-25T12:00:00Z` |
| `ajTenantId` | Keyword (optional) | Multi-tenancy support | `"tenant-123"` |
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** This is the main gem entrypoint defining the `ActiveJob::Temporal` module. It contains the `Configuration` class with validation methods (`validate!`, `validate_target!`, etc.), the `Error` base exception class, `ConfigurationError`, and module-level methods like `config`, `client`, `cancel`, and `configure`.
    *   **Current Exception Classes (lines 42-43):**
        ```ruby
        class Error < StandardError; end
        class ConfigurationError < Error; end
        ```
    *   **Recommendation:** You MUST add two new exception classes here after line 43:
        ```ruby
        class WorkflowNotFoundError < Error; end
        class TemporalConnectionError < Error; end
        ```
        These should inherit from the base `Error` class and be placed right after `ConfigurationError` to maintain logical grouping of exception types.

*   **File:** `lib/activejob/temporal/cancel.rb`
    *   **Summary:** This file contains the cancellation logic in the `ActiveJob::Temporal::Cancel` module. The current implementation (70 lines) calls `client.workflow_handle(workflow_id).cancel` and handles `RPCError` with `NOT_FOUND` code to suppress "workflow not found" errors. It uses `ActiveJob::Temporal::Logger` for logging.
    *   **Current Implementation Structure:**
        - Line 19-27: `cancel(job_class, job_id)` public method
        - Line 21: Direct call to `workflow_handle().cancel`
        - Line 22: Logs cancellation requested event
        - Line 23-26: Rescue block that catches errors and checks `workflow_not_found?`
        - Line 31-33: `build_workflow_id` helper (already exists)
        - Line 35-46: `workflow_not_found?` error detection logic (handles missing SDK gracefully)
        - Line 48-65: Logging methods
    *   **Recommendation:** You MUST significantly refactor this file. The new structure should be:
        1. **Add private `find_workflow(client, job_class, job_id)` method** that:
           - Queries Temporal using `client.list_workflows` API with search attribute filter
           - Syntax: `client.list_workflows(query: "ajJobId='#{job_id}'")`
           - First checks for running workflows: Query with `ExecutionStatus='Running'`
           - If not found, checks closed workflows: Query with `ExecutionStatus IN ('Completed', 'Failed', 'Cancelled', 'Terminated', 'TimedOut', 'ContinuedAsNew')`
           - Returns symbol: `:running`, `:closed`, or `:not_found`
           - Wraps all queries in rescue block to catch connection errors → raise `TemporalConnectionError`
        2. **Refactor `cancel(job_class, job_id)` method** to:
           - Call `find_workflow` to determine workflow state first
           - If `:closed`: Log with `Logger.warn` and `return false`
           - If `:not_found`: Raise `WorkflowNotFoundError.new("No workflow found for job_id #{job_id}. The job may have never existed.")`
           - If `:running`: Proceed with existing cancellation logic (workflow_handle + cancel)
           - Update YARD doc comment to reflect new return value: `@return [Boolean, nil] Returns false if workflow already completed, nil if cancelled successfully`

*   **File:** `lib/activejob/temporal/client.rb`
    *   **Summary:** This module provides the `Client.build(configuration)` method that connects to Temporal. It wraps Temporal connection errors in `ActiveJob::Temporal::Error` (lines 64-72). It handles TLS configuration from environment variables.
    *   **Error Handling Pattern (lines 64-72):**
        ```ruby
        rescue StandardError => e
          raise ActiveJob::Temporal::Error,
                format(
                  "Unable to connect to Temporal at %<target>s (namespace: %<namespace>s): %<error>s",
                  target: configuration.target,
                  namespace: configuration.namespace,
                  error: e.message
                )
        end
        ```
    *   **Recommendation:** You SHOULD use a similar error wrapping pattern in your `find_workflow` method when catching connection errors. Wrap them in `TemporalConnectionError` with descriptive messages that include the job_id and original error message.

*   **File:** `lib/activejob/temporal/logger.rb`
    *   **Summary:** Provides structured JSON logging with methods: `log_event`, `info`, `warn`, `error`. All methods accept `event_name` (String/Symbol) and `attributes` (Hash). The `warn` method logs at WARN level (lines 57-59).
    *   **Usage Pattern:**
        ```ruby
        Logger.warn("event_name", attribute1: value1, attribute2: value2)
        # Outputs: {"event": "event_name", "timestamp": "2025-10-31T...", "attribute1": value1, ...}
        ```
    *   **Recommendation:** You MUST use `Logger.warn` (not `Logger.log_event` or `Logger.info`) when logging completed workflows. Example:
        ```ruby
        ActiveJob::Temporal::Logger.warn(
          "cancellation_workflow_already_completed",
          workflow_id: workflow_id,
          job_class: job_class.name,
          job_id: job_id,
          status: "completed"
        )
        ```

*   **File:** `spec/unit/cancel_spec.rb`
    *   **Summary:** Contains comprehensive unit tests for the Cancel module (182 lines). Tests cover: successful cancellation (lines 52-68), workflow not found with NOT_FOUND error code (lines 70-95), different RPC error codes (lines 97-113), missing constants (lines 115-145), and error re-raising scenarios (lines 147-179). Tests use mocked `Temporalio::Error::RPCError` class.
    *   **Current Test Structure:**
        - Lines 27-43: Setup with mocked client, workflow_handle, and logger
        - Lines 44-50: Before block that stubs methods
        - Lines 52-68: Success case test
        - Lines 70-95: NOT_FOUND error handling test
        - Lines 97-179: Edge case tests for error handling
    *   **Recommendation:** You MUST add the following new test contexts:
        1. **"when workflow is already completed"** - Mock `find_workflow` to return `:closed`, assert `cancel` returns `false`, assert `Logger.warn` is called with event "cancellation_workflow_already_completed"
        2. **"when workflow never existed"** - Mock `find_workflow` to return `:not_found`, assert `WorkflowNotFoundError` is raised with message containing job_id
        3. **"when Temporal connection fails"** - Mock `find_workflow` to raise `StandardError` (simulating connection error), assert `TemporalConnectionError` is raised
        4. **Update existing success test** - Add stub for `find_workflow` to return `:running` before the cancel call
    *   **Note:** You can keep the existing RPC error tests for backward compatibility, but they may become less relevant since the new implementation queries workflow state first.

### Implementation Tips & Notes

*   **Tip:** The Temporal Ruby SDK's `list_workflows` API returns an enumerator. Use `.first` to get the first matching workflow: `client.list_workflows(query: "...").first`. If no workflows match, it returns `nil`.

*   **Tip:** The search attribute filter syntax for Temporal queries is SQL-like. For job_id filtering:
    ```ruby
    query = "ajJobId='#{job_id}' AND ExecutionStatus='Running'"
    ```
    For multiple statuses, use `IN`:
    ```ruby
    query = "ajJobId='#{job_id}' AND ExecutionStatus IN ('Completed', 'Failed', 'Cancelled')"
    ```

*   **Tip:** When iterating on closed workflow statuses, include all terminal states:
    - `Completed` - Workflow finished successfully
    - `Failed` - Workflow failed permanently
    - `Cancelled` - Workflow was cancelled
    - `Terminated` - Workflow was forcibly terminated
    - `TimedOut` - Workflow exceeded execution timeout
    - `ContinuedAsNew` - Workflow continued as new execution (treat as "completed" for cancellation purposes)

*   **Note:** The current implementation already handles the case where `Temporalio::Error::RPCError` is not defined (lines 36-45 in cancel.rb). You should preserve this defensive programming pattern when adding new error handling. However, the new approach (querying workflow state first) may make this pattern less critical since you're catching connection errors earlier.

*   **Note:** The task asks to "add integration test if not already present" in `spec/integration/cancellation_spec.rb`. Based on the directory listing and task data from I4.T7, an integration test for cancellation already exists. You should verify if it needs updates to test the new return values and exceptions. Specifically, you may want to add a test that:
    1. Enqueues a job
    2. Waits for it to complete
    3. Attempts to cancel it
    4. Asserts the return value is `false`

*   **Warning:** When querying Temporal's `list_workflows`, be aware of eventual consistency. Workflows that just completed may briefly appear in both running and closed lists, or may be missing from queries. The two-query approach (running first, then closed) helps mitigate this, but perfect consistency isn't guaranteed. Document this limitation in code comments.

*   **Warning:** The `cancel` method signature changes behavior: it now returns `false` for completed workflows instead of always returning `nil`. You MUST update the YARD documentation comment (currently line 13 in cancel.rb) to reflect this:
    ```ruby
    # @return [Boolean, nil] Returns false if workflow already completed, nil if cancelled successfully
    ```

*   **Implementation Pattern:** Recommended structure for `find_workflow` method:
    ```ruby
    def find_workflow(client, job_class, job_id)
      workflow_id = build_workflow_id(job_class, job_id)

      # Query running workflows
      running_query = "ajJobId='#{job_id}' AND ExecutionStatus='Running'"
      running = client.list_workflows(query: running_query).first
      return :running if running

      # Query closed workflows
      closed_query = "ajJobId='#{job_id}' AND ExecutionStatus IN ('Completed', 'Failed', 'Cancelled', 'Terminated', 'TimedOut', 'ContinuedAsNew')"
      closed = client.list_workflows(query: closed_query).first
      return :closed if closed

      :not_found
    rescue StandardError => e
      raise TemporalConnectionError,
            "Failed to query Temporal workflows for job_id #{job_id}: #{e.message}"
    end
    ```

*   **Testing Strategy:**
    - **Unit tests:** Mock the `list_workflows` method to return stub workflow objects (or `nil`) with different statuses. Mock `find_workflow` to return the three symbols (`:running`, `:closed`, `:not_found`) to test each branch.
    - **Integration tests (if updating):** Actually enqueue a job, let it complete, then try to cancel it and verify the return value is `false`. This requires the full Temporal test server setup from I4.T2.

*   **Rubocop Considerations:** The new `find_workflow` method may trigger complexity warnings if implemented naively. Consider extracting query string building into separate methods if needed:
    ```ruby
    def running_workflows_query(job_id)
      "ajJobId='#{job_id}' AND ExecutionStatus='Running'"
    end

    def closed_workflows_query(job_id)
      "ajJobId='#{job_id}' AND ExecutionStatus IN ('Completed', 'Failed', 'Cancelled', 'Terminated', 'TimedOut', 'ContinuedAsNew')"
    end
    ```

### Step-by-Step Implementation Plan

1. **Add Exception Classes** (lib/activejob/temporal.rb)
   - Add `WorkflowNotFoundError` after line 43
   - Add `TemporalConnectionError` after `WorkflowNotFoundError`

2. **Implement `find_workflow` method** (lib/activejob/temporal/cancel.rb)
   - Add as private method after `build_workflow_id`
   - Query running workflows first
   - Query closed workflows second
   - Return appropriate symbol
   - Wrap in rescue block for connection errors

3. **Refactor `cancel` method** (lib/activejob/temporal/cancel.rb)
   - Call `find_workflow` at the beginning
   - Add conditional logic for `:closed` case (log + return false)
   - Add conditional logic for `:not_found` case (raise WorkflowNotFoundError)
   - Keep existing logic for `:running` case
   - Update YARD documentation

4. **Update Unit Tests** (spec/unit/cancel_spec.rb)
   - Add test for completed workflow (returns false)
   - Add test for non-existent workflow (raises WorkflowNotFoundError)
   - Add test for connection error (raises TemporalConnectionError)
   - Update existing success test to mock `find_workflow`

5. **Verify Integration Tests** (spec/integration/cancellation_spec.rb)
   - Check if test exists for completed workflow cancellation
   - Add test if missing

6. **Run Quality Checks**
   - Run `rake spec` - all tests must pass
   - Run `rake rubocop` - no offenses
