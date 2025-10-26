# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I2.T1",
  "iteration_id": "I2",
  "iteration_goal": "Implement the core Temporal workflow (AjWorkflow) and activity (AjRunnerActivity) that orchestrate and execute ActiveJob jobs. Generate sequence diagrams for execution flows.",
  "description": "Create PlantUML sequence diagrams illustrating the detailed execution flows described in Section 3.7 (API Design & Communication). Generate three sequence diagrams: (1) Job Enqueue Flow (`docs/diagrams/enqueue_sequence.puml`) - showing the flow from Rails `perform_later` call → ActiveJob → TemporalAdapter → Payload serialization → Retry mapping → Search attributes → Temporal Client → Temporal Cluster workflow start. Include both immediate enqueue and scheduled enqueue (`set(wait:)`) variations. (2) Workflow & Activity Execution Flow (`docs/diagrams/execution_sequence.puml`) - showing Worker polling → AjWorkflow.execute → Workflow.sleep (if scheduled) → execute_activity → AjRunnerActivity.execute → Payload deserialization → Job instantiation → job.perform → External API call → Activity completion → Workflow completion. (3) Cancellation Flow (`docs/diagrams/cancellation_sequence.puml`) - showing Rails `cancel(job_id)` → Cancellation API → Workflow handle retrieval → handle.cancel → Temporal signal → Worker receives cancellation → Activity heartbeat → Cancellation acknowledged. Use standard PlantUML sequence diagram syntax with participants for each component. Diagrams must render without errors and accurately reflect the flows described in the plan.",
  "agent_type_hint": "DocumentationAgent",
  "inputs": "Section 3.7 (Key Interaction Flows: Enqueue, Execution, Cancellation), PlantUML sequence diagram syntax",
  "target_files": [
    "docs/diagrams/enqueue_sequence.puml",
    "docs/diagrams/execution_sequence.puml",
    "docs/diagrams/cancellation_sequence.puml"
  ],
  "input_files": [],
  "deliverables": "Three PlantUML sequence diagram files accurately depicting execution flows",
  "acceptance_criteria": "All three diagram files exist in `docs/diagrams/`; Diagrams use PlantUML sequence diagram syntax (`participant`, `->`, `-->`, `activate`, `deactivate`, `alt`, `note`); Diagrams render without syntax errors in PlantUML processor; Enqueue sequence diagram shows: Developer → Rails App → ActiveJob → TemporalAdapter → Payload → RetryMapper → SearchAttributes → Client → Temporal Cluster, with workflow_id and task_queue resolution steps; Execution sequence diagram shows: Temporal → Worker → AjWorkflow → Temporal (sleep if scheduled) → execute_activity → Worker → AjRunnerActivity → Payload deserialization → Job class → External API → Activity complete → Workflow complete; Cancellation sequence diagram shows: Developer → Rails → CancelAPI → Client → Temporal → Worker → Activity (heartbeat) → Cancellation error → Activity cancelled; Diagrams include notes explaining key concepts (e.g., \"Worker thread not blocked during sleep\", \"Idempotency key set here\")",
  "dependencies": [],
  "parallelizable": true,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: Enqueue Flow Documentation (from architecture Section 3.7)

The architecture document provides complete PlantUML diagram code for the job enqueue flow. This diagram shows the interaction between Developer, Rails App, ActiveJob, TemporalAdapter, Payload Serializer, Retry Mapper, Search Attrs, Temporal Client, and Temporal Cluster. Key steps include:
1. Developer calls `perform_later`
2. ActiveJob creates job instance with UUID job_id
3. Adapter serializes payload, maps retry policy, builds search attributes
4. Workflow ID is generated as `"ajwf:#{job_class}:#{job_id}"`
5. Task queue is resolved from job.queue_name
6. Client calls `start_workflow` with all parameters
7. Temporal persists workflow and returns handle

The scheduled enqueue variation shows how `scheduled_at` is passed in the payload and how the workflow starts immediately but sleeps internally.

### Context: Execution Flow Documentation (from architecture Section 3.7)

The execution flow diagram shows Worker polling for tasks, AjWorkflow executing with optional sleep for scheduled jobs, activity execution with AjRunnerActivity, payload deserialization, job instantiation, and job.perform call. Critical details include:
- Worker thread is NOT blocked during Workflow.sleep
- State is persisted in Temporal during sleep
- Idempotency key is set: `Thread.current[:aj_temporal_idempotency_key] = "ajwf:#{job_class}:#{job_id}/runner"`
- Activity completes and reports back to Temporal
- Workflow marks as Completed

Error handling sub-flows show retryable vs non-retryable exceptions using RetryMapper.discard_exception?.

### Context: Cancellation Flow Documentation (from architecture Section 3.7)

The cancellation diagram shows the flow from `ActiveJob::Temporal.cancel(job_id)` through building the workflow_id, getting workflow handle, calling `handle.cancel`, and Temporal propagating the cancellation signal. Two scenarios are shown:
1. Activity heartbeating: Receives CancelledError and can abort early
2. Activity NOT heartbeating: Completes normally, workflow marked as cancelled afterward

Best practice noted: Jobs should call `Temporalio::Activity.heartbeat` periodically for prompt cancellation.

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `docs/diagrams/component_overview.puml`
    *   **Summary:** This is an existing C4 component diagram that uses PlantUML syntax with the C4-PlantUML library. It demonstrates the project's preferred PlantUML style and provides examples of how components are named.
    *   **Recommendation:** You SHOULD use similar PlantUML syntax for your sequence diagrams. Study the participant naming conventions (e.g., `enqueue_handler`, `workflow_orchestrator`, `payload_module`) to maintain consistency.

*   **File:** `lib/activejob/temporal/payload.rb`
    *   **Summary:** This module provides `from_job(job, scheduled_at: nil)` which serializes ActiveJob arguments and `deserialize_args(payload)` which converts them back. The payload structure includes `job_class`, `job_id`, `queue_name`, `arguments`, `executions`, `exception_executions`, and optionally `scheduled_at` (as ISO8601 string).
    *   **Recommendation:** Your **enqueue sequence diagram** MUST show the adapter calling `Payload.from_job(job)`. Your **execution sequence diagram** MUST show `AjRunnerActivity` calling `Payload.deserialize_args(payload)`. These are critical integration points.

*   **File:** `lib/activejob/temporal/retry_mapper.rb`
    *   **Summary:** This module provides `for(job_class, exception = nil)` which returns a Temporal RetryPolicy hash with keys `initial_interval`, `backoff_coefficient`, `maximum_attempts`, and `non_retryable_error_types`. It also provides `discard_exception?(job_class, exception)` to check if an exception should be non-retryable.
    *   **Recommendation:** Your **enqueue sequence diagram** MUST show the adapter calling `RetryMapper.for(job_class)`. Your **execution sequence diagram** error flow MUST show the activity calling `RetryMapper.discard_exception?(job_class, exception)` when handling errors.

*   **File:** `lib/activejob/temporal/search_attributes.rb`
    *   **Summary:** This module provides `for(job)` which builds a hash of Temporal search attributes including `ajClass`, `ajQueue`, `ajJobId`, `ajEnqueuedAt`, and optionally `ajTenantId`.
    *   **Recommendation:** Your **enqueue sequence diagram** MUST show the adapter calling `SearchAttributes.for(job)` before starting the workflow.

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** This is the main entrypoint that defines the `Configuration` class and provides `ActiveJob::Temporal.config` (configuration singleton) and `ActiveJob::Temporal.client` (Temporal client singleton).
    *   **Recommendation:** Your **enqueue sequence diagram** should show the adapter accessing `ActiveJob::Temporal.client` to call `start_workflow`.

### Implementation Tips & Notes

*   **Tip:** The architecture documentation shows THREE distinct sequence diagrams. You MUST create three separate `.puml` files as specified in the task:
    1. `docs/diagrams/enqueue_sequence.puml` - Job Enqueue Flow
    2. `docs/diagrams/execution_sequence.puml` - Workflow & Activity Execution Flow
    3. `docs/diagrams/cancellation_sequence.puml` - Cancellation Flow

*   **Note:** The existing architecture documentation (Section 3.7) includes complete PlantUML diagram code blocks embedded in markdown. You MUST extract these diagrams and convert them to standalone `.puml` files. Pay close attention to:
    - Using `@startuml` / `@enduml` delimiters
    - Defining participants with `participant "Name" as Alias`
    - Using activation/deactivation (`activate`, `deactivate`)
    - Using alt blocks for conditional flows
    - Adding explanatory notes with `note right of`, `note left of`

*   **Tip:** The **enqueue sequence diagram** must show BOTH immediate enqueue AND scheduled enqueue variations. Use an `alt` block to distinguish between these two flows. The architecture doc shows them in separate diagrams, but the task acceptance criteria says to include both variations in one diagram for the enqueue flow.

*   **Warning:** The cancellation sequence diagram MUST show the workflow_id being constructed in the format `"ajwf:SendInvoiceJob:job-uuid-123"`. This is mentioned in the architecture docs and is critical for the cancellation API to work correctly. Make sure this detail is visible in your diagram.

*   **Note:** The execution sequence diagram must clearly show that `Workflow.sleep` does NOT block the worker thread. Include a note stating "Worker can process other tasks" and "State persisted in Temporal" to emphasize this critical architectural point.

*   **Tip:** For the idempotency key in the execution diagram, show it being set to `Thread.current[:aj_temporal_idempotency_key] = "ajwf:SendInvoiceJob:#{job_id}/runner"` and then cleared in an ensure block. This is explicitly mentioned in the architecture docs.

*   **Note:** The cancellation diagram must show the distinction between activities that heartbeat (can be cancelled promptly) vs activities that don't heartbeat (complete normally, then workflow is marked as cancelled). Use an `alt` block to show both scenarios.

*   **Important:** The diagrams are embedded in the architecture docs as markdown code blocks starting with ~~~plantuml. You need to extract the diagram code (everything between @startuml and @enduml) and save it as standalone .puml files. Review the architecture document Section 3.7 carefully to get the complete diagram source code.

*   **Style Note:** Follow the naming conventions used in the existing component diagram. Use descriptive aliases like `Dev`, `Rails`, `AJ`, `Adapter`, `Payload`, `Retry`, `Search`, `Client`, `Temporal`, `Worker`, `Workflow`, `Activity`, `Job`, `External`.
