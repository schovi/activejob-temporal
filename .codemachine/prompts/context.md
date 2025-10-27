# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I3.T5",
  "iteration_id": "I3",
  "iteration_goal": "Implement the ActiveJob adapter (TemporalAdapter) that integrates with Rails, and the cancellation API. This connects all previous components to enable actual job enqueue and cancellation.",
  "description": "Create `lib/activejob/temporal/cancel.rb` with the cancellation API module. Implement `ActiveJob::Temporal.cancel(job_class, job_id)` class method with the following logic: (1) Build workflow_id from job_id. This requires knowing the job class name, but job_id alone is not sufficient (workflow_id format is `ajwf:<ClassName>:<job_id>`). Use `cancel(job_class, job_id)` signature for v0.1 to maintain deterministic workflow_id format. (1) Builds workflow_id = `\"ajwf:#{job_class.name}:#{job_id}\"`. (2) Gets Temporal client using `ActiveJob::Temporal.client`. (3) Gets workflow handle: `handle = client.get_workflow_handle(workflow_id)`. (4) Calls `handle.cancel`. (5) Logs cancellation event. (6) Handles errors: if workflow not found or already completed, log warning but don't raise exception (best-effort cancellation). Write unit tests in `spec/unit/cancel_spec.rb` covering: successful cancellation, workflow not found error handling, logging. Mock `client.get_workflow_handle` and `handle.cancel`.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Section 3.7 (Key Interaction Flow: Cancellation), Client module from I1.T4, Logger from I1.T8, workflow_id format from I2.T4",
  "target_files": [
    "lib/activejob/temporal/cancel.rb",
    "spec/unit/cancel_spec.rb",
    "lib/activejob/temporal.rb"
  ],
  "input_files": [
    "lib/activejob/temporal/client.rb",
    "lib/activejob/temporal/logger.rb"
  ],
  "deliverables": "Working cancellation API, passing unit tests, documented API method",
  "acceptance_criteria": "`ActiveJob::Temporal.cancel(job_class, job_id)` method is defined; Workflow ID is built correctly: `\"ajwf:#{job_class.name}:#{job_id}\"`; `client.workflow_handle(workflow_id)` is called; `handle.cancel` is called; Log event \"cancellation_requested\" is written with workflow_id, job_class, job_id; If workflow not found (handle raises exception), error is caught, warning logged, method returns gracefully (doesn't raise); Unit tests mock `client.workflow_handle` and `handle.cancel`; Unit tests verify: successful cancel, workflow not found handling, logging; `rake spec` passes for cancel_spec.rb; Code passes `rake rubocop`; API is documented in code comments (YARD format: `@param job_class [Class]`, `@param job_id [String]`, `@return [void]`)",
  "dependencies": [
    "I1.T4",
    "I1.T8",
    "I2.T4"
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
#### **Key Interaction Flow 4: Job Cancellation**

**Scenario**: User cancels an in-flight job via `ActiveJob::Temporal.cancel(job_id)`.

**Steps**:

1. **Developer calls cancel**: Invokes `ActiveJob::Temporal.cancel(job_class, job_id)` (e.g., via Rails console or admin endpoint).
2. **Cancellation API**: `lib/activejob/temporal/cancel.rb` module handles the request.
3. **Build workflow ID**: Deterministic workflow ID is constructed: `"ajwf:SendInvoiceJob:job-uuid-123"`.
   - **Note**: This requires knowing the job class name. API signature for v0.1 is `cancel(job_class, job_id)` to avoid needing a database lookup.
4. **Get workflow handle**: Uses `client.workflow_handle(workflow_id)` to obtain a handle to the running workflow.
5. **Send cancel signal**: Calls `handle.cancel` to send cancellation request to Temporal cluster.
6. **Temporal signals worker**: Cluster forwards cancellation to the worker process executing the workflow.
7. **Activity heartbeat check**:
   - If the job (AjRunnerActivity) is calling `Temporalio::Activity.heartbeat` periodically, Temporal injects a `CancelledError` exception on the next heartbeat, allowing the activity to abort promptly.
   - If the job does NOT heartbeat, the activity runs to completion; cancellation only marks the workflow as cancelled post-completion (i.e., "lazy cancellation").
8. **Logging**: Cancellation event is logged with workflow_id, job_class, job_id.
9. **Error handling**: If workflow is not found (already completed or never existed), log a warning but do not raise an exception (best-effort cancellation).

**Error Handling Behavior**:
- **Workflow not found**: Temporal returns an error if the workflow doesn't exist. This is handled gracefully (log warning, return).
- **Already completed**: If the workflow finished before cancellation was processed, cancellation has no effect; log warning.
- **Network error**: If Temporal is unreachable, an exception is raised to the caller (not caught).
```

### Context: decision-workflow-id-deduplication (from 06_Rationale_and_Future.md)

```markdown
#### **Decision 2: Workflow ID Format for Deduplication**

**Decision**: Use deterministic workflow IDs derived from the job's ID: `"ajwf:<JobClassName>:<job.job_id>"`. Temporal's "reject" ID conflict policy ensures a single workflow exists per job, preventing duplicate execution if `perform_later` is called multiple times with the same job_id (e.g., due to retry or race condition in application code).

**Rationale**:
- **Idempotent Enqueue**: If the same job (identified by job_id) is enqueued multiple times (e.g., duplicate API request, retryable HTTP calls), Temporal's ID conflict policy (`:reject`) ensures only one workflow is started. Subsequent enqueue attempts are rejected with a workflow-already-started error, which the adapter logs but does not raise to the caller (graceful deduplication).
- **Workflow Retrieval**: The deterministic ID format allows job cancellation and status queries without needing a database lookup: given job_class and job_id, the workflow_id can be reconstructed.
- **Class Name Inclusion**: Including the job class name prevents collisions between different job classes that might (by chance) use the same UUID for job_id (unlikely but possible if UUIDs are generated independently). This is critical for cancellation: `cancel(job_class, job_id)` can build the correct workflow_id.

**Trade-offs**:
- **Cancellation API Signature**: Requires passing both `job_class` and `job_id` to cancellation API, instead of just `job_id`. This is a minor API inconvenience but necessary to maintain deterministic workflow_id format.
  - *Alternative considered*: Store job_id → job_class mapping in a database or cache. Rejected: adds operational complexity (another data store dependency) and doesn't align with Temporal's "stateless client" philosophy.
- **Class Name Changes**: If a job class is renamed (e.g., `SendInvoiceJob` → `InvoiceMailerJob`), existing in-flight workflows will retain the old class name in their workflow_id. This is acceptable: workflow_id is immutable, and renaming is a rare, coordinated event.
```

### Context: Communication Error Handling (from 04_Behavior_and_Communication.md)

```markdown
### **3.7.5. Communication Error Handling**

Error handling for communication between components is critical for resilience. The gem categorizes errors into two phases:

#### **Cancellation Error Handling**

**Cancellation-Time Errors** occur when `ActiveJob::Temporal.cancel` is called:

1. **Workflow Not Found**:
   - **Cause**: Workflow has already completed, never existed, or was already cancelled.
   - **Handling**: Catch the error, log a WARNING event "cancellation_workflow_not_found" with workflow_id, job_class, job_id. Return gracefully WITHOUT raising exception.
   - **Rationale**: Cancellation is best-effort. If workflow is already gone, cancellation is moot.

2. **Temporal Connection Failure**:
   - **Cause**: Temporal cluster is unreachable (network issue, server down).
   - **Handling**: Allow exception to bubble up to caller as `ActiveJob::Temporal::Error` with descriptive message.
   - **Rationale**: Connection errors should be visible to the caller so they can retry or alert operations team.

3. **Permission Denied / Auth Failure**:
   - **Cause**: Credentials invalid or namespace access denied.
   - **Handling**: Allow exception to bubble up.
   - **Rationale**: This is a configuration error that needs immediate attention.

**Note**: Cancellation does NOT guarantee the activity stops immediately. It only sends a cancellation signal. Activities that heartbeat can detect cancellation promptly; others will run to completion.
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** This is the main entry point for the gem. It defines the `ActiveJob::Temporal` module with configuration management (lines 19-70) and class methods for `config` and `client` (lines 72-88).
    *   **Recommendation:** You MUST add two things to this file:
        1. Add `require_relative "temporal/cancel"` after line 12 (after the adapter require)
        2. Add a class method `cancel(job_class, job_id)` that delegates to `Cancel.cancel(job_class, job_id)` around line 88
    *   **Pattern to Follow:** Look at the `client` method (lines 80-82) which uses a similar delegation pattern - it calls `Client.build(config)`. Your cancel method should delegate to the Cancel module.
    *   **Important:** The module uses `class << self` starting at line 72 to define class methods. Your cancel method should be added inside this block.

*   **File:** `lib/activejob/temporal/client.rb`
    *   **Summary:** This module provides the `build(configuration)` method to create a Temporal client connection. It handles TLS configuration and connection errors. The client uses `Temporalio::Client.connect` to establish the connection.
    *   **Recommendation:** DO NOT modify this file. Use `ActiveJob::Temporal.client` to access the client instance. The client is already built using this module and memoized in the main module.
    *   **Note:** The client that's returned supports the `workflow_handle(workflow_id)` method which returns a handle object.

*   **File:** `lib/activejob/temporal/logger.rb`
    *   **Summary:** This module provides structured JSON logging with methods `log_event`, `info`, `warn`, and `error` (lines 11-25). It automatically adds timestamp and event name, and supports both standard Logger and SemanticLogger.
    *   **Recommendation:** You MUST use this logger for all logging in your cancel implementation. For successful cancellation, use `Logger.log_event("cancellation_requested", attributes)`. For workflow-not-found errors, use `Logger.warn("cancellation_workflow_not_found", attributes)`.
    *   **API Pattern:** `Logger.log_event(event_name, attribute_hash)` where attribute_hash contains workflow_id, job_class, job_id.
    *   **Example:** `ActiveJob::Temporal::Logger.log_event("cancellation_requested", workflow_id: wf_id, job_class: job_class.name, job_id: job_id)`

*   **File:** `lib/activejob/temporal/adapter.rb`
    *   **Summary:** This file contains helper methods `build_workflow_id(job)` and `resolve_task_queue(job)` in the `ActiveJob::Temporal::Adapter` module (lines 7-31). The workflow_id format is defined at line 14: `"ajwf:#{job.class.name}:#{job.job_id}"`.
    *   **Recommendation:** You CANNOT directly use `build_workflow_id` because it requires a full job instance, but your cancel method only has job_class and job_id. You MUST manually construct the workflow_id using the same pattern: `"ajwf:#{job_class.name}:#{job_id}"`.
    *   **Critical:** The format MUST match exactly - including the "ajwf:" prefix and the two colons as separators.

*   **File:** `vendor/bundle/ruby/3.3.0/gems/temporalio-1.0.0-arm64-darwin/lib/temporalio/client.rb`
    *   **Summary:** The Temporal Ruby SDK client. The method you need is `client.workflow_handle(workflow_id, run_id: nil, first_execution_run_id: nil, result_hint: nil)` which returns a `WorkflowHandle` instance (lines 201-210 in the SDK).
    *   **Recommendation:** Call `handle = client.workflow_handle(workflow_id)` to get the handle (no additional parameters needed for v0.1). Then call `handle.cancel` to send the cancellation signal.
    *   **Important:** The `workflow_handle` method does NOT validate that the workflow exists - it just creates a handle object. The actual error (workflow not found) will be raised when you call `handle.cancel`, not during handle creation.

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** This file contains sample ActiveJob classes used in tests, including SimpleJob, ScheduledJob, RetryableJob, DiscardableJob, etc. The ApplicationJob stub (lines 9-22) provides the minimal interface needed for testing.
    *   **Recommendation:** You SHOULD use `SimpleJob` in your unit tests for `cancel_spec.rb`. You'll need to create a mock job instance with a specific job_id for testing.
    *   **Pattern:** In tests, create a job instance like: `job = SimpleJob.new; job.job_id = "test-123"; job`

*   **File:** `spec/unit/adapter_spec.rb`
    *   **Summary:** Contains comprehensive unit tests with extensive mocking patterns (lines 75-323). Tests use RSpec with describe/context/it blocks, let statements for test data, and `allow().to receive()` for mocking.
    *   **Recommendation:** Follow the SAME testing patterns in your cancel_spec.rb. Look at how the adapter tests mock `ActiveJob::Temporal.config`, `ActiveJob::Temporal.client`, and `Logger.log_event` (lines 139-163 show good mocking examples).
    *   **Mocking Pattern:** Use `allow(ActiveJob::Temporal).to receive(:client).and_return(mock_client)` to mock the client, then mock methods on `mock_client`.

### Implementation Tips & Notes

*   **Tip #1: Workflow ID Construction**
    - You cannot use `Adapter.build_workflow_id` because it requires a full job object
    - You MUST manually construct: `workflow_id = "ajwf:#{job_class.name}:#{job_id}"`
    - The format is CRITICAL - must match exactly what the adapter uses for enqueue
    - Test this carefully - wrong format means cancellation won't find the workflow

*   **Tip #2: Error Handling Strategy**
    - The SDK likely raises an exception when calling `handle.cancel` on a non-existent workflow
    - You need to catch this exception and log a warning instead of propagating it
    - Check if the Temporal SDK defines error classes like `Temporalio::Error::WorkflowNotFoundError` or similar
    - Follow the pattern from adapter.rb lines 105-109 which checks `defined?(Temporalio::Client::WorkflowAlreadyStartedError)`
    - Use a broad rescue for StandardError if specific error classes aren't documented

*   **Tip #3: Module Structure**
    - Create a MODULE (not a class) in `lib/activejob/temporal/cancel.rb`
    - Use `module_function` to make the cancel method callable as a module method
    - Pattern:
      ```ruby
      module ActiveJob
        module Temporal
          module Cancel
            module_function

            def cancel(job_class, job_id)
              # implementation
            end
          end
        end
      end
      ```

*   **Tip #4: Logging Details**
    - For successful cancellation: `Logger.log_event("cancellation_requested", workflow_id:, job_class: job_class.name, job_id:)`
    - For workflow not found: `Logger.warn("cancellation_workflow_not_found", workflow_id:, job_class: job_class.name, job_id:, error: e.message)`
    - Include the error message in the warning log for debugging purposes

*   **Tip #5: Test Structure**
    Your `spec/unit/cancel_spec.rb` should have this structure:
    ```ruby
    require "spec_helper"
    require_relative "../fixtures/sample_jobs"

    RSpec.describe ActiveJob::Temporal::Cancel do
      describe ".cancel" do
        let(:job_class) { SimpleJob }
        let(:job_id) { "test-job-123" }
        let(:workflow_id) { "ajwf:SimpleJob:test-job-123" }
        let(:mock_client) { instance_double(Temporalio::Client) }
        let(:mock_handle) { instance_double(Temporalio::Client::WorkflowHandle) }

        before do
          allow(ActiveJob::Temporal).to receive(:client).and_return(mock_client)
          allow(mock_client).to receive(:workflow_handle).with(workflow_id).and_return(mock_handle)
        end

        context "when workflow exists" do
          # test successful cancellation
        end

        context "when workflow not found" do
          # test error handling
        end

        context "logging" do
          # test logging calls
        end
      end
    end
    ```

*   **Tip #6: YARD Documentation Format**
    Based on existing code patterns, use this documentation format:
    ```ruby
    # Cancels a running Temporal workflow by sending a cancellation request.
    # This is a best-effort operation - if the workflow has already completed
    # or does not exist, a warning is logged but no exception is raised.
    #
    # @param job_class [Class] The ActiveJob class for the job to cancel
    # @param job_id [String] The unique job ID (UUID)
    # @return [void]
    # @raise [ActiveJob::Temporal::Error] if Temporal cluster is unreachable
    #
    # @example Cancel a running job
    #   ActiveJob::Temporal.cancel(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
    ```

*   **Warning: Don't Validate Job Class**
    - DO NOT validate that job_class is a valid ActiveJob class
    - Just use `job_class.name` to get the class name string
    - If job_class doesn't respond to .name, Ruby will raise an error anyway
    - Keep the implementation simple - let Ruby's method dispatch handle validation

*   **Warning: Test Workflow Handle Creation**
    - Remember: `client.workflow_handle(workflow_id)` creates a handle WITHOUT checking if workflow exists
    - The error happens when you call `handle.cancel`
    - Your tests should mock BOTH: `client.workflow_handle` returning a handle, AND `handle.cancel` which might raise
    - Don't mock cancel to raise on the handle creation step

*   **Note: Network Errors Should Bubble Up**
    - According to the architecture, only workflow-not-found errors should be caught
    - Connection errors should propagate to the caller
    - Be specific in your rescue clause - only catch workflow-not-found errors, not all StandardErrors
    - This might require checking error class or message content

*   **Note: Integration with Main Module**
    - After creating the Cancel module, you must integrate it into `ActiveJob::Temporal`
    - Add `require_relative "temporal/cancel"` to load the module
    - Add `def cancel(job_class, job_id); Cancel.cancel(job_class, job_id); end` as a class method
    - This allows users to call `ActiveJob::Temporal.cancel(...)` directly

### Testing Strategy

*   **Test Case 1: Successful Cancellation**
    - Mock client.workflow_handle to return a mock handle
    - Mock handle.cancel to succeed (no return value needed)
    - Verify workflow_id is constructed correctly
    - Verify Logger.log_event is called with "cancellation_requested" and correct attributes

*   **Test Case 2: Workflow Not Found**
    - Mock handle.cancel to raise an error (determine correct error class from SDK)
    - Verify Logger.warn is called with "cancellation_workflow_not_found"
    - Verify method returns normally (doesn't re-raise exception)
    - Verify warning log includes error message

*   **Test Case 3: Network Error** (Optional for v0.1)
    - Mock client.workflow_handle to raise a connection error
    - Verify exception bubbles up to caller (not caught)
    - This tests that only workflow-not-found errors are caught, not all errors

*   **Test Case 4: Workflow ID Format**
    - Verify the constructed workflow_id matches: "ajwf:#{job_class.name}:#{job_id}"
    - Test with different job classes and IDs
    - Ensure format is deterministic

*   **Mock Setup Pattern:**
    ```ruby
    let(:mock_client) { instance_double(Temporalio::Client) }
    let(:mock_handle) { instance_double(Temporalio::Client::WorkflowHandle) }

    before do
      allow(ActiveJob::Temporal).to receive(:client).and_return(mock_client)
      allow(mock_client).to receive(:workflow_handle).and_return(mock_handle)
      allow(ActiveJob::Temporal::Logger).to receive(:log_event)
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
    end
    ```

### Success Criteria Checklist

To complete this task successfully, you MUST implement:

✅ **Core Implementation:**
- [ ] Create `lib/activejob/temporal/cancel.rb` with Cancel module
- [ ] Implement `Cancel.cancel(job_class, job_id)` method
- [ ] Construct workflow_id: `"ajwf:#{job_class.name}:#{job_id}"`
- [ ] Call `client = ActiveJob::Temporal.client`
- [ ] Call `handle = client.workflow_handle(workflow_id)`
- [ ] Call `handle.cancel`
- [ ] Log event "cancellation_requested" on success
- [ ] Catch workflow-not-found errors and log warning instead of raising
- [ ] Let network errors bubble up to caller

✅ **Integration:**
- [ ] Add `require_relative "temporal/cancel"` to `lib/activejob/temporal.rb`
- [ ] Add `cancel(job_class, job_id)` class method to `ActiveJob::Temporal` module

✅ **Testing:**
- [ ] Create `spec/unit/cancel_spec.rb`
- [ ] Test successful cancellation with correct workflow_id
- [ ] Test workflow-not-found error handling
- [ ] Test logging calls (both success and error)
- [ ] Mock `ActiveJob::Temporal.client`, `client.workflow_handle`, `handle.cancel`, and Logger methods
- [ ] Verify `bundle exec rake spec` passes

✅ **Documentation:**
- [ ] Add YARD documentation to cancel method with @param, @return, @raise, @example
- [ ] Document best-effort nature of cancellation
- [ ] Explain when exceptions are raised vs. caught

✅ **Code Quality:**
- [ ] Follow project conventions (frozen_string_literal, 2-space indent, etc.)
- [ ] Verify `bundle exec rake rubocop` passes with zero offenses
- [ ] Follow existing patterns from adapter.rb and logger.rb

### Recommended Implementation Order

**Step 1: Create Cancel Module (15 minutes)**
1. Create `lib/activejob/temporal/cancel.rb`
2. Define module structure with `module_function`
3. Implement core cancel logic:
   - Build workflow_id
   - Get client
   - Get handle
   - Call cancel
   - Log success
   - Handle errors with rescue

**Step 2: Integrate with Main Module (5 minutes)**
1. Edit `lib/activejob/temporal.rb`
2. Add require statement after line 12
3. Add cancel class method around line 88

**Step 3: Create Comprehensive Tests (20 minutes)**
1. Create `spec/unit/cancel_spec.rb`
2. Set up test structure with describe/context/it
3. Create let blocks for test fixtures
4. Create before block with mocks
5. Write 3-4 test cases covering all scenarios

**Step 4: Verify and Polish (10 minutes)**
1. Run `bundle exec rake spec` - verify new tests pass
2. Run `bundle exec rake rubocop` - fix any offenses
3. Review YARD documentation format
4. Verify acceptance criteria checklist

**Total estimated time:** ~50 minutes
