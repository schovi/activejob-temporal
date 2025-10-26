# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I2.T4",
  "iteration_id": "I2",
  "iteration_goal": "Implement the core Temporal workflow (AjWorkflow) and activity (AjRunnerActivity) that orchestrate and execute ActiveJob jobs. Generate sequence diagrams for execution flows.",
  "description": "Create a helper method in `lib/activejob/temporal/adapter.rb` (or a separate helper module) for building deterministic workflow IDs. Implement `build_workflow_id(job)` method that returns a string in format `\"ajwf:#{job.class.name}:#{job.job_id}\"`. This ensures idempotent enqueue (same job_id → same workflow_id → Temporal rejects duplicate via `:reject` conflict policy). Write unit tests in `spec/unit/adapter_spec.rb` (this spec will be expanded in I3) covering: workflow ID format, determinism (same job → same ID), uniqueness across job classes. This is a small helper but critical for deduplication.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Section 3.7 (Interaction Flow - Workflow ID Generation), ActiveJob job structure",
  "target_files": [
    "lib/activejob/temporal/adapter.rb",
    "spec/unit/adapter_spec.rb"
  ],
  "input_files": [],
  "deliverables": "Working workflow ID builder, passing unit tests",
  "acceptance_criteria": "`build_workflow_id(job)` returns string in format `\"ajwf:<ClassName>:<job_id>\"`; Example: For `SendInvoiceJob` with job_id \"abc-123\", returns `\"ajwf:SendInvoiceJob:abc-123\"`; Calling `build_workflow_id` twice with same job returns same string (deterministic); Different job classes with same job_id return different workflow IDs (class name prevents collision); Unit tests verify format and determinism; `rake spec` passes for adapter_spec.rb; Code passes `rake rubocop`",
  "dependencies": [],
  "parallelizable": true,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: interaction-flow-enqueue (from 04_Behavior_and_Communication.md)

```markdown
#### **Key Interaction Flow 1: Job Enqueue (Immediate Execution)**

**Scenario**: Rails application enqueues a job for immediate execution via `perform_later`.

**Key Steps:**

1. **Developer calls `perform_later`**: Rails ActiveJob captures job class, arguments, and generates a UUID `job_id`
2. **ActiveJob calls adapter**: Invokes `TemporalAdapter.enqueue(job)`
3. **Payload serialization**: Converts ActiveJob arguments to JSON-compatible format
4. **Retry policy mapping**: Inspects job class's `retry_on`/`discard_on` declarations, builds Temporal `RetryPolicy`
5. **Search attributes building**: Extracts metadata (`ajClass`, `ajQueue`, etc.) for Temporal visibility
6. **Workflow ID generation**: Creates deterministic ID `ajwf:SendInvoiceJob:<job_id>` (enables deduplication)
7. **Task queue resolution**: Maps job's `queue_name` to Temporal task queue (with optional prefix)
8. **Temporal workflow start**: Calls `client.start_workflow` (gRPC to Temporal cluster)
9. **Temporal persists workflow**: Creates workflow in `Scheduled` state, returns workflow run handle
10. **Enqueue completes**: Rails call returns immediately (doesn't wait for job to execute)

From the sequence diagram, the adapter internally calls:
```
Adapter -> Adapter : workflow_id = "ajwf:SendInvoiceJob:#{job.job_id}"
Adapter -> Adapter : task_queue = "billing"

Adapter -> Client : client.start_workflow(
  AjWorkflow,
  serialized_payload,
  id: workflow_id,
  task_queue: task_queue,
  id_conflict_policy: :reject,
  search_attributes: {...}
)
```

**Communication Protocols:**
- Rails ↔ Gem: Ruby method calls (in-process)
- Gem ↔ Temporal: gRPC over HTTP/2 (network call, ~50-100ms latency)
```

### Context: decision-workflow-id-deduplication (from 06_Rationale_and_Future.md)

```markdown
#### **Decision 2: Deterministic Workflow ID + :reject Conflict Policy**

**Choice:** Generate workflow IDs as `ajwf:<JobClass>:<job_id>` with `:reject` conflict policy.

**Rationale:**

- **Idempotency**: Prevents duplicate job execution if `perform_later` is called twice (e.g., due to retry logic)
- **Debuggability**: Workflow ID embeds job class and UUID, making it easy to correlate in logs/UI
- **Temporal Best Practice**: Workflow IDs should be deterministic and meaningful

**Trade-offs:**

| Benefit | Cost |
|---------|------|
| Guarantees no duplicate workflows | Cannot re-enqueue same job_id (must generate new UUID) |
| Easy to find workflows in Temporal UI | Workflow ID collisions raise errors (not silent failures) |

**Alternatives Considered:**

1. **Random Workflow IDs**: Generate UUID for each workflow
   - **Rejected**: Loses deduplication; same job could run twice
2. **Use Only job_id**: Workflow ID = job_id (no class prefix)
   - **Rejected**: Collisions across job classes (e.g., two jobs with same UUID)

**Caveat**: If job_id is reused across different job classes, collisions still occur (addressed by including class name in ID).
```

### Context: task-i2-t4 (from 02_Iteration_I2.md)

```markdown
*   **Task 2.4: Implement Workflow ID Builder Helper**
    *   **Task ID:** `I2.T4`
    *   **Description:** Create a helper method in `lib/activejob/temporal/adapter.rb` (or a separate helper module) for building deterministic workflow IDs. Implement `build_workflow_id(job)` method that returns a string in format `"ajwf:#{job.class.name}:#{job.job_id}"`. This ensures idempotent enqueue (same job_id → same workflow_id → Temporal rejects duplicate via `:reject` conflict policy). Write unit tests in `spec/unit/adapter_spec.rb` (this spec will be expanded in I3) covering: workflow ID format, determinism (same job → same ID), uniqueness across job classes. This is a small helper but critical for deduplication.
    *   **Acceptance Criteria:**
        - `build_workflow_id(job)` returns string in format `"ajwf:<ClassName>:<job_id>"`
        - Example: For `SendInvoiceJob` with job_id "abc-123", returns `"ajwf:SendInvoiceJob:abc-123"`
        - Calling `build_workflow_id` twice with same job returns same string (deterministic)
        - Different job classes with same job_id return different workflow IDs (class name prevents collision)
        - Unit tests verify format and determinism
        - `rake spec` passes for adapter_spec.rb
        - Code passes `rake rubocop`
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** This is the main module file for the gem. It contains the `Configuration` class and module-level methods like `config`, `configure`, and `client`. The module is already properly structured with all foundation components loaded via `require_relative` statements (lines 6-12).
    *   **Recommendation:** You MUST add `require_relative "temporal/adapter"` after line 12 to ensure the adapter module is loaded when the gem is required. This follows the existing pattern used for other modules.

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** This file contains sample ActiveJob classes used for testing. It includes both custom `ApplicationJob` classes (SimpleJob, ScheduledJob) and ActiveJob::Base classes (RetryableJob, DiscardableJob, etc.). The `ApplicationJob` mock class (lines 10-22) defines the minimal interface: `job_id`, `queue_name`, `executions`, `exception_executions`, and `arguments` attributes.
    *   **Recommendation:** You MUST use these sample job classes in your tests. Create instances like `job = SimpleJob.new` and set `job.job_id = "test-123"` for testing. This ensures your tests work with both the mock ApplicationJob and real ActiveJob::Base classes.

*   **File:** `lib/activejob/temporal/payload.rb`
    *   **Summary:** This file demonstrates the gem's coding style and structure. It uses a module with `extend self` pattern (line 10), contains both public and private methods, follows frozen_string_literal convention, and shows proper error handling with `ActiveJob::SerializationError`.
    *   **Recommendation:** Your adapter.rb file SHOULD follow the same pattern - use a module with `extend self` and `module_function` for utility methods. This is consistent with other utility modules in the gem.

*   **File:** `lib/activejob/temporal/activities/aj_runner_activity.rb`
    *   **Summary:** This file already uses workflow_id in its implementation (line 40): `workflow_id = Temporalio::Activity.info&.workflow_id || "unknown-workflow"` and constructs the idempotency key as `"#{workflow_id}/runner"` (line 41).
    *   **Recommendation:** This confirms that the workflow_id format pattern is already being consumed by the activity runner. Your `build_workflow_id` method MUST generate IDs in the exact format that the activity expects to parse and use.

*   **File:** `spec/unit/workflows/aj_workflow_spec.rb` and other spec files
    *   **Summary:** These files show the project's RSpec testing patterns: use of `describe`, `context`, `it` blocks, proper use of `let` for setup, mocking with `allow().to receive()`, and comprehensive test coverage.
    *   **Recommendation:** Follow the same RSpec structure and style for your `adapter_spec.rb`. Use descriptive test names like `"returns workflow ID in correct format"` and organize related tests in `context` blocks.

### Implementation Tips & Notes

*   **Tip:** The workflow ID format is CRITICAL for the entire system. The format `"ajwf:#{job.class.name}:#{job.job_id}"` is used in multiple places:
    1. In the adapter to create deterministic workflow IDs (this task)
    2. In the activity runner to construct idempotency keys (already implemented)
    3. In the cancellation API (I3.T5) to rebuild workflow IDs from job_class and job_id

    Your implementation MUST follow this exact format with NO variations.

*   **Tip:** The gem does NOT yet have a `lib/activejob/temporal/adapter.rb` file. You MUST create it from scratch. Based on the codebase patterns, structure it as:
    ```ruby
    # frozen_string_literal: true

    module ActiveJob
      module Temporal
        module Adapter
          extend self

          # Builds a deterministic workflow ID from an ActiveJob instance
          # @param job [ActiveJob::Base] The job instance
          # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
          def build_workflow_id(job)
            "ajwf:#{job.class.name}:#{job.job_id}"
          end

          module_function :build_workflow_id
        end
      end
    end
    ```

*   **Note:** The unit test file `spec/unit/adapter_spec.rb` does NOT exist yet. You must create it from scratch. Based on other spec files:
    - Use `require "spec_helper"` at the top
    - Use RSpec describe/context/it blocks
    - Create mock job objects using sample jobs from `spec/fixtures/sample_jobs.rb`
    - Test the method with different job classes and job_ids to verify uniqueness

*   **Warning:** The Rubocop configuration at `.rubocop.yml` is fairly strict. Based on reviewing other files:
    - Use `# frozen_string_literal: true` comment at the top
    - Use double quotes for strings (not single quotes)
    - Follow the style of existing modules (Payload, RetryMapper, etc.)
    - Keep methods simple and focused (this one should be ~3 lines)

*   **Important:** According to the architecture documentation, the `:reject` conflict policy relies on deterministic workflow IDs. This means:
    - Same job instance → same workflow_id → Temporal rejects duplicate (idempotent)
    - Different job classes with same job_id → different workflow_ids (class name prevents collision)
    - Your tests MUST verify both scenarios

*   **Note:** The method should be simple and stateless - just string interpolation. DO NOT:
    - Call any external services or APIs
    - Read from configuration
    - Perform validation on the job object
    - Generate new IDs or UUIDs
    - Add any caching or memoization

    Simply format the existing `job.class.name` and `job.job_id` into the required format.

*   **Testing Strategy:** Your spec should test at minimum:
    1. **Format verification**: Assert the exact string format `"ajwf:JobClassName:job-id"`
    2. **Determinism**: Calling twice with same job returns same ID
    3. **Uniqueness**: Two different job classes with same job_id produce different workflow IDs
    4. **Multiple job classes**: Test with different job types (SimpleJob, ScheduledJob, RetryableJob)

    Use `let` blocks to create sample jobs with specific job_ids for predictable testing:
    ```ruby
    let(:simple_job) do
      job = SimpleJob.new
      job.job_id = "abc-123"
      job
    end
    ```

*   **Code Style Requirements:**
    - Use `# frozen_string_literal: true` at the top of both files
    - Use double quotes for strings
    - Use 2-space indentation
    - Add YARD documentation comments above the method
    - Follow the module structure pattern from other utility modules

*   **Performance Note:** This method will be called frequently (on every job enqueue), so keep it extremely simple and fast. No I/O, no complex computation - just pure string interpolation.

*   **Integration Context:** While you're only implementing a helper method now, understand that:
    - In I3.T1, this method will be called from `TemporalAdapter.enqueue(job)`
    - The workflow ID will be passed to `client.start_workflow(id: workflow_id, ...)`
    - The ID format must match what cancellation API expects to reconstruct

### Suggested Test Structure

Your `spec/unit/adapter_spec.rb` should include these test cases:

```ruby
# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/adapter"

RSpec.describe ActiveJob::Temporal::Adapter do
  describe ".build_workflow_id" do
    context "with a simple job" do
      let(:job) do
        job = SimpleJob.new
        job.job_id = "abc-123"
        job
      end

      it "returns workflow ID in correct format" do
        expect(described_class.build_workflow_id(job)).to eq("ajwf:SimpleJob:abc-123")
      end

      it "is deterministic (same job, same ID)" do
        first_call = described_class.build_workflow_id(job)
        second_call = described_class.build_workflow_id(job)
        expect(first_call).to eq(second_call)
      end
    end

    context "with different job classes" do
      let(:simple_job) do
        job = SimpleJob.new
        job.job_id = "same-id"
        job
      end

      let(:scheduled_job) do
        job = ScheduledJob.new
        job.job_id = "same-id"
        job
      end

      it "produces different workflow IDs for different classes" do
        simple_id = described_class.build_workflow_id(simple_job)
        scheduled_id = described_class.build_workflow_id(scheduled_job)

        expect(simple_id).to eq("ajwf:SimpleJob:same-id")
        expect(scheduled_id).to eq("ajwf:ScheduledJob:same-id")
        expect(simple_id).not_to eq(scheduled_id)
      end
    end

    context "with different job IDs" do
      it "produces different workflow IDs" do
        job1 = SimpleJob.new
        job1.job_id = "id-1"

        job2 = SimpleJob.new
        job2.job_id = "id-2"

        id1 = described_class.build_workflow_id(job1)
        id2 = described_class.build_workflow_id(job2)

        expect(id1).to eq("ajwf:SimpleJob:id-1")
        expect(id2).to eq("ajwf:SimpleJob:id-2")
        expect(id1).not_to eq(id2)
      end
    end
  end
end
```

---

## 4. Summary & Next Steps

### What You're Building
A simple but critical helper method that generates deterministic workflow IDs for Temporal workflows. The method takes an ActiveJob instance and returns a formatted string.

### Key Requirements
1. **Format**: Exactly `"ajwf:#{job.class.name}:#{job.job_id}"`
2. **Determinism**: Same job → same ID every time
3. **Uniqueness**: Different job classes with same UUID → different IDs (class name differentiates)
4. **Testing**: Comprehensive tests covering format, determinism, and uniqueness
5. **Style**: Follow existing gem patterns (frozen_string_literal, double quotes, YARD docs)

### Files to Create
1. `lib/activejob/temporal/adapter.rb` - The adapter module with build_workflow_id method
2. `spec/unit/adapter_spec.rb` - Comprehensive unit tests

### Files to Modify
1. `lib/activejob/temporal.rb` - Add `require_relative "temporal/adapter"` after line 12

### Success Criteria
✓ Create adapter.rb with build_workflow_id method
✓ Create adapter_spec.rb with comprehensive tests
✓ Format returns exactly `"ajwf:<ClassName>:<job_id>"`
✓ Tests verify format, determinism, uniqueness
✓ All tests pass (`rake spec`)
✓ Code passes style checks (`rake rubocop`)
✓ Adapter module is properly required from main gem file
