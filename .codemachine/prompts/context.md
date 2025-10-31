# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I6.T5",
  "iteration_id": "I6",
  "iteration_goal": "Enhance Version 2 with robust validation, better error handling, and comprehensive documentation from Version 1 analysis while maintaining Version 2's superior architecture.",
  "description": "Create Architecture Decision Records (ADR) documentation structure in `docs/adr/` folder. Use standard ADR format with sections: Title, Status (Accepted/Proposed/Deprecated), Context, Decision, Consequences. Create the following ADRs: (1) `001-structured-logging.md` - Document decision to use structured JSON logging with event names instead of plain text logs, context: observability requirements for production systems, decision: implement Logger module with JSON output and event-based semantics, consequences: better integration with log aggregation tools but requires JSON parsing; (2) `002-iso8601-timestamps.md` - Document decision to use ISO8601 timestamp format for scheduled_at instead of Unix timestamps, context: readability and timezone handling, decision: use Time.iso8601 parsing in workflows, consequences: human-readable but slightly larger payload; (3) `003-adapter-helper-module.md` - Document decision to extract workflow ID building and task queue resolution into separate Adapter helper module instead of inline in queue adapter, context: code organization and reusability, decision: create Adapter module with build_workflow_id and resolve_task_queue methods, consequences: better separation of concerns and testability; (4) `004-idempotency-keys.md` - Document decision to provide thread-local idempotency keys in activity execution, context: enabling idempotent external API calls, decision: set Thread.current[:aj_temporal_idempotency_key] in AjRunnerActivity, consequences: jobs can use idempotency keys for safe retries but must handle thread-local access. Each ADR should be 100-200 lines with detailed context, alternatives considered, and specific code examples.",
  "agent_type_hint": "DocumentationAgent",
  "inputs": "Version 1 docs/adr/ (structure reference), Version 2 architecture decisions, ADR template format (https://github.com/joelparkerhenderson/architecture-decision-record)",
  "target_files": [
    "docs/adr/001-structured-logging.md",
    "docs/adr/002-iso8601-timestamps.md",
    "docs/adr/003-adapter-helper-module.md",
    "docs/adr/004-idempotency-keys.md",
    "docs/adr/README.md"
  ],
  "input_files": [],
  "deliverables": "ADR folder with 4 detailed architecture decision records and README explaining the ADR process",
  "acceptance_criteria": "docs/adr/ folder exists; docs/adr/README.md exists explaining what ADRs are and how to create new ones; 001-structured-logging.md exists with sections: Title ('ADR 001: Structured JSON Logging'), Status (Accepted), Context (observability requirements), Decision (Logger module with JSON output), Consequences (pros/cons); 002-iso8601-timestamps.md exists documenting ISO8601 vs Unix timestamp decision; 003-adapter-helper-module.md exists documenting Adapter module extraction; 004-idempotency-keys.md exists documenting thread-local idempotency key design; Each ADR follows consistent format and is 100-200 lines; Each ADR includes code examples showing the implemented solution; ADRs are written in clear, technical language suitable for new maintainers; All Markdown files pass markdownlint (if configured)",
  "dependencies": [],
  "parallelizable": true,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: logging-strategy (from 05_Operational_Architecture.md)

```markdown
##### **Logging Strategy**

**Structured Logging (JSON Format)**

The gem emits structured logs to `Rails.logger` (configurable via `ActiveJob::Temporal.config.logger`).

**Log Events & Attributes:**

| Event | Level | Attributes | Example |
|-------|-------|------------|---------|
| **Workflow Enqueued** | `info` | `workflow_id`, `run_id`, `job_class`, `job_id`, `queue`, `scheduled_at` (optional) | `{"event": "workflow_enqueued", "workflow_id": "ajwf:SendInvoiceJob:abc123", ...}` |
| **Activity Started** | `info` | `workflow_id`, `run_id`, `activity_id`, `job_class`, `attempt` | `{"event": "activity_started", "attempt": 1, ...}` |
| **Activity Completed** | `info` | `workflow_id`, `duration_ms`, `job_class` | `{"event": "activity_completed", "duration_ms": 1234, ...}` |
| **Activity Failed** | `error` | `workflow_id`, `attempt`, `exception_class`, `exception_message`, `backtrace` (first 5 lines) | `{"event": "activity_failed", "exception_class": "PSP::TransientError", ...}` |
| **Activity Retry** | `warn` | `workflow_id`, `attempt`, `next_retry_interval`, `exception_class` | `{"event": "activity_retry", "attempt": 2, "next_retry_interval": 60, ...}` |
| **Cancellation Requested** | `warn` | `workflow_id`, `job_id`, `reason` (optional) | `{"event": "cancellation_requested", ...}` |
| **Cancellation Acknowledged** | `info` | `workflow_id`, `activity_id` | `{"event": "cancellation_acknowledged", ...}` |
| **Payload Size Warning** | `warn` | `job_class`, `payload_size_kb`, `limit_kb` | `{"event": "payload_size_warning", "payload_size_kb": 200, ...}` |
| **Serialization Error** | `error` | `job_class`, `job_id`, `exception_class`, `exception_message` | `{"event": "serialization_error", ...}` |

**Logger Configuration:**

```ruby
# config/initializers/activejob_temporal.rb
ActiveJob::Temporal.configure do |c|
  c.logger = SemanticLogger['ActiveJobTemporal'] # or Rails.logger
end
```

**Best Practices:**

- **Include Correlation IDs**: Always log `workflow_id` and `run_id` for traceability
- **Redact Sensitive Data**: Do not log job arguments directly (may contain PII); log argument count or types only
- **Use Semantic Logger**: Recommended for JSON output + tagging support
```

### Context: Data Model - Scheduled Execution (from 03_System_Structure_and_Data.md)

The architecture specifies that `scheduled_at` is stored as an **ISO8601 String** format:

- Format: `"2025-10-25T12:00:00Z"`
- Used in payload serialization
- Parsed in workflow with `Time.iso8601(timestamp)`

### Context: Observability Requirements (from 05_Operational_Architecture.md)

```markdown
##### **Payload Security**

**2. Payload Size Limits**

- **Default Limit**: 250KB per job payload
- **Rationale**: Prevent DoS attacks via large payloads; respect Temporal's 2MB history limit
- **Enforcement**: Check payload size after serialization, raise `SerializationError` if exceeded
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal/logger.rb`
    *   **Summary:** This file implements the structured JSON logging system with event-based semantics. It provides `Logger.info()`, `Logger.warn()`, `Logger.error()` methods that accept event names (e.g., "job.enqueued") and structured attributes. All logs include `event`, `timestamp` (ISO8601), and custom attributes.
    *   **Recommendation:** You MUST reference this implementation in ADR 001. Extract code examples from lines 35-48 (the public API methods) and lines 74-95 (the internal JSON payload building logic) to demonstrate the design decision.
    *   **Key Design Pattern:** The logger uses `build_payload(event_name, attributes)` to create a hash with `{ event: ..., timestamp: current_timestamp }.merge(attributes)` structure, then serializes to JSON for standard Ruby Logger or passes directly to SemanticLogger.

*   **File:** `lib/activejob/temporal/workflows/aj_workflow.rb`
    *   **Summary:** This workflow implementation demonstrates the ISO8601 timestamp parsing design. The `extract_scheduled_time(payload)` method (lines 82-87) extracts the `scheduled_at` field and parses it with `Time.iso8601(timestamp)`. The workflow then uses `Temporalio::Workflow.sleep(delay)` for durable scheduling.
    *   **Recommendation:** You MUST reference this in ADR 002. Show the `extract_scheduled_time` method as the concrete implementation of the ISO8601 decision. Contrast this with what a Unix timestamp approach would look like (e.g., `Time.at(timestamp)`).
    *   **Key Design Pattern:** Using `Time.iso8601()` for parsing and `Time.now.utc.iso8601` for serialization ensures human-readable, timezone-aware timestamps.

*   **File:** `lib/activejob/temporal/adapter.rb`
    *   **Summary:** This file contains the Adapter helper module (lines 11-53) with two critical methods: `build_workflow_id(job)` and `resolve_task_queue(job)`. These were extracted into a separate module instead of being inline in the TemporalAdapter class (lines 85-219).
    *   **Recommendation:** You MUST reference this in ADR 003. Explain the separation of concerns: the `Adapter` module provides stateless, testable helper functions that the `TemporalAdapter` class uses. This allows independent unit testing of workflow ID generation without needing to instantiate the full adapter.
    *   **Key Design Pattern:** Module-level functions (`module_function`) for stateless utilities, called as `ActiveJob::Temporal::Adapter.build_workflow_id(job)`. This avoids instance state and enables easy mocking in tests.

*   **File:** `lib/activejob/temporal/activities/aj_runner_activity.rb`
    *   **Summary:** This activity implementation sets and clears the thread-local idempotency key. The key logic is in `set_idempotency_key` (lines 132-142) which sets `Thread.current[:aj_temporal_idempotency_key] = "#{workflow_id}/runner"` before job execution, and clears it in the `ensure` block (line 120).
    *   **Recommendation:** You MUST reference this in ADR 004. Extract the idempotency key pattern and explain why it uses thread-local storage (activities may run concurrently in the same process). Show the full lifecycle: set → execute → ensure clear.
    *   **Key Design Pattern:** Thread-local storage with a constant `IDEMPOTENCY_KEY = :aj_temporal_idempotency_key` (line 85) ensures no key collisions. The workflow ID is used as the base for the key, making it unique per job execution.

### Implementation Tips & Notes

*   **Tip:** The ADR format is well-documented at https://github.com/joelparkerhenderson/architecture-decision-record. The standard structure is:
    1. **Title:** Short, descriptive (e.g., "ADR 001: Structured JSON Logging")
    2. **Status:** Accepted/Proposed/Deprecated/Superseded
    3. **Context:** The issue or problem being addressed (2-3 paragraphs)
    4. **Decision:** What was decided (1-2 paragraphs + code examples)
    5. **Consequences:** Positive and negative outcomes (bulleted lists)
    6. **Alternatives Considered:** (Optional but valuable) What other approaches were evaluated

*   **Tip:** Each ADR should be 100-200 lines. Use code fences (```) liberally to show concrete implementations. ADRs are most valuable when they include:
    - **Before/After examples** showing the old and new approach
    - **Trade-offs** explaining why one approach was chosen over alternatives
    - **Links** to external resources (Temporal docs, Ruby stdlib docs, etc.)

*   **Note:** The `docs/adr/README.md` should explain:
    - What ADRs are and why they're valuable (architectural memory)
    - How to create a new ADR (copy template, increment number, fill sections)
    - How to supersede an old ADR (reference in the "Superseded by" section)
    - Link to the ADR template repository for more information

*   **Note:** For ADR 001 (Structured Logging), compare the event-based JSON approach against:
    - Plain text logging: `logger.info "Enqueued job MyJob with ID 123"` (harder to parse)
    - Tag-based logging: Using Rails tagged logging with brackets (less structured)
    - Explain why the `{ event: ..., timestamp: ..., ...attrs }` structure is better for log aggregation tools (Elasticsearch, Splunk, Datadog)

*   **Note:** For ADR 002 (ISO8601 Timestamps), compare against:
    - Unix timestamps (integers): More compact but less readable, timezone ambiguity
    - Ruby Time objects: Can't be serialized to JSON directly
    - Explain the trade-off: ISO8601 adds ~10-15 bytes per timestamp but gains human readability and explicit timezone info (always UTC with 'Z' suffix)

*   **Note:** For ADR 003 (Adapter Helper Module), explain:
    - **Before:** If methods were inline in TemporalAdapter, they'd be instance methods tied to adapter lifecycle
    - **After:** Module-level functions can be called without instantiating an adapter, enabling better unit testing
    - **Alternative Considered:** Could have been a separate class (`WorkflowIdBuilder`, `TaskQueueResolver`), but that felt over-engineered for 2 simple methods

*   **Note:** For ADR 004 (Idempotency Keys), explain:
    - **Context:** Jobs may call external APIs that need idempotency tokens (e.g., Stripe, payment processors)
    - **Why Thread-Local:** Workers run multiple activities concurrently in the same process; thread-local ensures isolation
    - **Access Pattern:** Jobs can read `Thread.current[:aj_temporal_idempotency_key]` in their `perform` method to get the key
    - **Alternative Considered:** Passing as an argument to `perform` would require changing ActiveJob's API, which we want to avoid

*   **Warning:** The task specifies the `docs/adr/` folder does NOT currently exist in Version 2 (I confirmed this). You MUST create it. The Version 1 repository has an empty `docs/adr/` folder, so there are no existing ADRs to reference—you are creating the first ADRs for this project.

*   **Important:** The acceptance criteria specify each ADR should be "100-200 lines" and include "code examples showing the implemented solution." Ensure you extract actual code snippets from the implementation files I've analyzed above. Don't write pseudocode—use the real, working code from the current codebase.

*   **Quality Check:** After creating the ADRs, they should answer these questions for a new maintainer:
    - Why was structured logging chosen over plain text?
    - Why ISO8601 instead of Unix timestamps?
    - Why split Adapter helpers into a module instead of keeping them inline?
    - Why use thread-local storage for idempotency keys?

    If a reader can't answer these questions after reading your ADRs, they need more detail.

### Directory Structure Notes

- Current state: `docs/` folder exists with `configuration_reference.md`, `migration_guide.md`, `worker_setup.md`, `diagrams/` subfolder
- Required: Create new `docs/adr/` subfolder with 5 files total (README.md + 4 ADRs)
- Naming convention: Use zero-padded numbers (001, 002, 003, 004) for ordering
- File extension: Use `.md` (Markdown) for all ADRs

### Standard ADR Template Structure

```markdown
# ADR XXX: [Title]

## Status

[Accepted/Proposed/Deprecated/Superseded by ADR-YYY]

## Context

[2-3 paragraphs describing the problem, constraints, requirements]

## Decision

[1-2 paragraphs describing what was decided]

[Code examples showing the implementation]

## Consequences

### Positive

- [Benefit 1]
- [Benefit 2]

### Negative

- [Drawback 1]
- [Drawback 2]

## Alternatives Considered

### [Alternative 1]

[Why it was not chosen]

### [Alternative 2]

[Why it was not chosen]
```

---

## Final Checklist for Coder Agent

Before marking this task complete, ensure:

1. ✅ `docs/adr/` directory created
2. ✅ `docs/adr/README.md` exists with ADR process explanation
3. ✅ `docs/adr/001-structured-logging.md` exists with all required sections
4. ✅ `docs/adr/002-iso8601-timestamps.md` exists with all required sections
5. ✅ `docs/adr/003-adapter-helper-module.md` exists with all required sections
6. ✅ `docs/adr/004-idempotency-keys.md` exists with all required sections
7. ✅ Each ADR is 100-200 lines long
8. ✅ Each ADR includes concrete code examples from the actual implementation
9. ✅ All ADRs use consistent formatting (Status, Context, Decision, Consequences, Alternatives)
10. ✅ ADRs are written in clear, technical language suitable for new maintainers
11. ✅ All Markdown files use proper formatting (headings, code fences, bullet lists)
