# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I3.T6",
  "iteration_id": "I3",
  "iteration_goal": "Implement the ActiveJob adapter (TemporalAdapter) that integrates with Rails, and the cancellation API. This connects all previous components to enable actual job enqueue and cancellation.",
  "description": "Review and update the cancellation sequence diagram created in I2.T1 (`docs/diagrams/cancellation_sequence.puml`) to reflect the actual implementation from I3.T5. Ensure the diagram shows the correct method signature (`cancel(job_class, job_id)`) and flow. Update any notes to clarify best-effort cancellation behavior (requires heartbeating for prompt abort). Verify diagram renders correctly.",
  "agent_type_hint": "DocumentationAgent",
  "inputs": "Cancellation API implementation from I3.T5, original sequence diagram from I2.T1",
  "target_files": [
    "docs/diagrams/cancellation_sequence.puml"
  ],
  "input_files": [
    "docs/diagrams/cancellation_sequence.puml",
    "lib/activejob/temporal/cancel.rb"
  ],
  "deliverables": "Updated and accurate cancellation sequence diagram",
  "acceptance_criteria": "Diagram reflects `cancel(job_class, job_id)` method signature; Diagram shows workflow_id construction, handle retrieval, cancel call; Diagram includes notes about best-effort cancellation and heartbeating requirement; Diagram renders without syntax errors in PlantUML",
  "dependencies": [
    "I3.T5"
  ],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: Cancellation Flow Design

The cancellation API is designed to provide best-effort cancellation of running Temporal workflows. The key architectural decisions are:

1. **Method Signature:** The API requires both `job_class` and `job_id` parameters because the deterministic workflow ID format is `ajwf:<ClassName>:<job_id>`. This allows the cancellation API to construct the exact workflow ID needed to request cancellation.

2. **Workflow ID Format:** The format `ajwf:#{job_class.name}:#{job_id}` is used consistently across enqueue and cancellation operations to ensure workflows can be reliably found and cancelled.

3. **Best-Effort Semantics:** If the workflow has already completed or doesn't exist, the cancellation request is logged as a warning but doesn't raise an error. This provides graceful degradation.

4. **Heartbeating Requirement:** For activities to respond promptly to cancellation, they must call `Temporalio::Activity.heartbeat` periodically. Without heartbeating, the activity may complete even after a cancellation signal is sent.

### Context: Alternative Approaches Considered

The architecture documents note that an alternative approach using Temporal Signals was considered but rejected in favor of the simpler `handle.cancel` approach for v0.1. The Signal-based approach would have required:
- Custom Signal handlers in the workflow
- Additional workflow code complexity
- More integration testing

The chosen approach of using `handle.cancel` directly provides simpler semantics and leverages Temporal's built-in cancellation mechanism.

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal/cancel.rb`
    *   **Summary:** This file implements the cancellation API with the actual method signature `ActiveJob::Temporal::Cancel.cancel(job_class, job_id)`. The implementation constructs the workflow_id, retrieves the workflow handle, and calls cancel on it. It includes error handling for workflow-not-found scenarios and proper logging.
    *   **Key Implementation Details:**
        - Line 19: Method signature is `cancel(job_class, job_id)`
        - Line 20: Workflow ID constructed as `"ajwf:#{job_class.name}:#{job_id}"`
        - Line 21: Uses `client.workflow_handle(workflow_id).cancel` to request cancellation
        - Lines 23-26: Best-effort error handling for workflow not found
        - Lines 48-65: Logging for both success and not-found scenarios
    *   **Recommendation:** You MUST update the diagram to reflect this exact implementation flow.

*   **File:** `lib/activejob/temporal/adapter.rb`
    *   **Summary:** Shows consistent workflow ID construction using `build_workflow_id(job)` which returns `"ajwf:#{job.class.name}:#{job.job_id}"` (line 14). This matches the format used by cancellation.
    *   **Recommendation:** The diagram should show this consistent workflow ID format to demonstrate how cancellation can deterministically find workflows.

*   **File:** `docs/diagrams/cancellation_sequence.puml`
    *   **Summary:** Current diagram has the incorrect method signature `cancel(job_id)` on line 12 and needs updates to match actual implementation.
    *   **Recommendation:** See detailed changes below.

### Implementation Tips & Notes

*   **Tip:** The current diagram has good structure with alt blocks showing heartbeating vs non-heartbeating scenarios (lines 26-38). Preserve this structure as it accurately represents the behavior.

*   **Note:** The diagram must emphasize that Cancel API accepts BOTH `job_class` and `job_id` parameters. This is not optional - the workflow ID format requires the class name.

*   **Note:** Line 20 mentions `reason = "user_request"` but the actual Ruby implementation (cancel.rb line 21) doesn't pass a reason parameter. The Ruby SDK's `cancel` method is called without arguments. You should remove or update this note.

*   **Tip:** The notes about deterministic workflow_id (line 16) and heartbeating (line 40) are critical and should be preserved/enhanced.

*   **Warning:** The diagram currently shows `handle = client.workflow_handle(AjWorkflow, workflow_id)` on line 17, but the actual implementation only passes `workflow_id`. The workflow type is not needed when retrieving a handle by ID.

### Required Changes to cancellation_sequence.puml

**Critical Updates:**

1. **Line 12:** Change from:
   ```
   Dev -> Rails: ActiveJob::Temporal.cancel(job_id)
   ```
   To:
   ```
   Dev -> Rails: ActiveJob::Temporal.cancel(SendInvoiceJob, "job-uuid-123")
   ```

2. **Line 13:** Change from:
   ```
   Rails -> Cancel: cancel(job_id)
   ```
   To:
   ```
   Rails -> Cancel: cancel(SendInvoiceJob, "job-uuid-123")
   ```

3. **Line 15:** Keep as is - already correct:
   ```
   Cancel -> Cancel: workflow_id = "ajwf:SendInvoiceJob:job-uuid-123"
   ```

4. **Line 17:** Change from:
   ```
   Cancel -> Client: ActiveJob::Temporal.client.workflow_handle(AjWorkflow, workflow_id)
   ```
   To:
   ```
   Cancel -> Client: client.workflow_handle(workflow_id)
   ```

5. **Line 18:** Update note to:
   ```
   note right of Client: Retrieves workflow handle by workflow_id only
   ```

6. **Line 19:** Change from:
   ```
   Client -> Temporal: handle.cancel()
   ```
   Keep the parentheses but note is correct. This line is fine.

7. **Line 20:** Remove or update the note about reason parameter:
   ```
   note right of Client: Sends cancellation request to Temporal cluster via gRPC API
   ```

### Testing the Diagram

After making changes:

1. **Syntax Validation:** Ensure all `alt` blocks have matching `end` statements (currently correct at line 38)
2. **Participant Definition:** All participants are defined at top (lines 4-10) - this is correct
3. **Activation/Deactivation:** Only Cancel is activated/deactivated (lines 14, 22) - this is correct
4. **Notes Position:** All notes use proper PlantUML note syntax

### Educational Content to Preserve

The diagram has excellent educational notes that should be preserved:
- Line 16: Explains deterministic workflow_id format
- Line 34: Warns about non-heartbeating activities
- Line 40: Emphasizes heartbeating best practice

These notes provide critical context for users understanding cancellation behavior.

### Final Verification

After updates, verify:
- Method signatures show `(job_class, job_id)` throughout
- Workflow ID construction is explicit and matches actual format
- Client API calls match Ruby SDK methods
- Error handling notes reflect best-effort semantics
- Heartbeating behavior is clearly explained
