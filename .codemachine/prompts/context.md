# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I2.T5",
  "iteration_id": "I2",
  "iteration_goal": "Implement the core Temporal workflow (AjWorkflow) and activity (AjRunnerActivity) that orchestrate and execute ActiveJob jobs. Generate sequence diagrams for execution flows.",
  "description": "Create a helper method in `lib/activejob/temporal/adapter.rb` (or helper module) for resolving Temporal task queue names from ActiveJob queue names. Implement `resolve_task_queue(job)` method that extracts `job.queue_name` (default to \"default\" if nil), applies `config.task_queue_prefix` (if present), and returns the final task queue string. Example: If `job.queue_name` is \"billing\" and `config.task_queue_prefix` is \"prod-\", return \"prod-billing\". If no prefix, return \"billing\". Write unit tests in `spec/unit/adapter_spec.rb` covering: task queue resolution with and without prefix, default queue name (\"default\"), nil queue_name handling.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Section 3.7 (Interaction Flow - Task Queue Resolution), configuration from I1.T3",
  "target_files": [
    "lib/activejob/temporal/adapter.rb",
    "spec/unit/adapter_spec.rb"
  ],
  "input_files": [
    "lib/activejob/temporal.rb"
  ],
  "deliverables": "Working task queue resolver, passing unit tests",
  "acceptance_criteria": "`resolve_task_queue(job)` returns task queue string; If `job.queue_name` is \"billing\" and `config.task_queue_prefix` is nil, returns \"billing\"; If `job.queue_name` is \"billing\" and `config.task_queue_prefix` is \"prod-\", returns \"prod-billing\"; If `job.queue_name` is nil, returns \"default\" (or \"prod-default\" with prefix); Unit tests cover all scenarios: with prefix, without prefix, nil queue_name, explicit queue_name; `rake spec` passes for adapter_spec.rb; Code passes `rake rubocop`",
  "dependencies": [
    "I1.T3"
  ],
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

### Context: task-i2-t5 (from 02_Iteration_I2.md)

```markdown
*   **Task 2.5: Implement Task Queue Resolver Helper**
    *   **Task ID:** `I2.T5`
    *   **Description:** Create a helper method in `lib/activejob/temporal/adapter.rb` (or helper module) for resolving Temporal task queue names from ActiveJob queue names. Implement `resolve_task_queue(job)` method that extracts `job.queue_name` (default to "default" if nil), applies `config.task_queue_prefix` (if present), and returns the final task queue string. Example: If `job.queue_name` is "billing" and `config.task_queue_prefix` is "prod-", return "prod-billing". If no prefix, return "billing". Write unit tests in `spec/unit/adapter_spec.rb` covering: task queue resolution with and without prefix, default queue name ("default"), nil queue_name handling.
    *   **Acceptance Criteria:**
        - `resolve_task_queue(job)` returns task queue string
        - If `job.queue_name` is "billing" and `config.task_queue_prefix` is nil, returns "billing"
        - If `job.queue_name` is "billing" and `config.task_queue_prefix` is "prod-", returns "prod-billing"
        - If `job.queue_name` is nil, returns "default" (or "prod-default" with prefix)
        - Unit tests cover all scenarios: with prefix, without prefix, nil queue_name, explicit queue_name
        - `rake spec` passes for adapter_spec.rb
        - Code passes `rake rubocop`
```

### Context: Configuration Reference - task_queue_prefix

```markdown
## Configuration Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `task_queue_prefix` | String or `nil` | `nil` | Optional prefix applied to every task queue name generated by the adapter. |

## Usage Examples

```ruby
# config/initializers/activejob_temporal.rb
ActiveJob::Temporal.configure do |config|
  config.target = "temporal.example.com:7233"
  config.namespace = "production"
  config.task_queue_prefix = "rails-"
  config.default_activity_timeout = 30.seconds
end
```

You can read the configuration anywhere after initialization:

```ruby
ActiveJob::Temporal.config.logger.info("Temporal target: #{ActiveJob::Temporal.config.target}")
```
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal/adapter.rb`
    *   **Summary:** This file currently contains ONLY the `build_workflow_id` method (lines 8-13). It uses a module structure with `module_function` to define utility methods. The module is properly documented with YARD comments.
    *   **Recommendation:** You MUST add the new `resolve_task_queue(job)` method to this same file, following the existing pattern. Add it right after the `build_workflow_id` method. Use the same YARD documentation style.

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** This is the main configuration module. The `Configuration` class (lines 19-70) defines all configuration options including `task_queue_prefix` (line 22, initialized to `nil` on line 34). The configuration is accessible via `ActiveJob::Temporal.config` (lines 73-75).
    *   **Recommendation:** Your method MUST read the configuration using `ActiveJob::Temporal.config.task_queue_prefix`. This is the ONLY way to access configuration in this gem.

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** This file contains mock job classes for testing. The `ApplicationJob` mock class (lines 10-22) defines the interface: it has a `queue_name` accessor (line 11) that defaults to `"default"` (line 16). The mock can be instantiated and its `queue_name` can be set to any value including `nil`.
    *   **Recommendation:** You MUST use these sample job classes in your tests. Create instances like `job = SimpleJob.new` and test different `queue_name` values: `nil`, `"default"`, `"billing"`, `"mailers"`, etc.

*   **File:** `spec/unit/adapter_spec.rb`
    *   **Summary:** This file currently contains tests for `build_workflow_id` method only (lines 7-68). It uses standard RSpec structure with `describe`, `context`, `let`, and `it` blocks. Tests are well-organized and descriptive.
    *   **Recommendation:** You MUST add a new `describe ".resolve_task_queue"` block to this file (after the existing describe block). Follow the same testing structure and patterns. Use `let` blocks for job setup and configuration mocking.

*   **File:** `lib/activejob/temporal/payload.rb`
    *   **Summary:** This file demonstrates the gem's utility module pattern. It uses `module Payload`, `extend self`, and `module_function` for defining utility methods (line 10). Methods are documented with YARD comments showing `@param`, `@return`, and descriptions.
    *   **Recommendation:** Follow the EXACT same pattern in adapter.rb. Your new method should be at the same level as `build_workflow_id` - both should be module functions that can be called as `Adapter.resolve_task_queue(job)`.

### Implementation Tips & Notes

*   **Tip:** The task queue resolution logic follows this pattern:
    1. Extract `queue_name` from job (use `job.queue_name`)
    2. Default to `"default"` if `queue_name` is `nil` or empty
    3. Read prefix from `ActiveJob::Temporal.config.task_queue_prefix`
    4. If prefix is present and not empty, prepend it: `"#{prefix}#{queue_name}"`
    5. Otherwise, return just the queue name

*   **Tip:** The method should be VERY simple - just string concatenation. NO:
    - Network calls or I/O
    - Complex validation or error handling
    - Caching or memoization
    - Side effects or logging

    Just pure string manipulation based on inputs.

*   **Note:** According to line 112 of the architecture doc, the task queue is used in the sequence diagram:
    ```
    Adapter -> Adapter : task_queue = "billing"
    ```
    This shows the task queue is resolved internally in the adapter before calling `client.start_workflow(task_queue: task_queue, ...)`.

*   **Warning:** The `task_queue_prefix` can be `nil` (the default). Your code MUST handle this gracefully:
    - If prefix is `nil`, return just the queue name
    - If prefix is an empty string `""`, treat it as no prefix
    - Only prepend prefix if it's a non-empty string

*   **Important:** The gem uses `# frozen_string_literal: true` at the top of EVERY file. You must NOT modify this in adapter.rb - it's already there.

*   **Testing Strategy:** Your tests MUST cover these scenarios:
    1. **No prefix, explicit queue**: `queue_name = "billing"`, `prefix = nil` → `"billing"`
    2. **No prefix, default queue**: `queue_name = nil`, `prefix = nil` → `"default"`
    3. **With prefix, explicit queue**: `queue_name = "billing"`, `prefix = "prod-"` → `"prod-billing"`
    4. **With prefix, default queue**: `queue_name = nil`, `prefix = "prod-"` → `"prod-default"`
    5. **Empty prefix**: `queue_name = "billing"`, `prefix = ""` → `"billing"`
    6. **Multiple queues**: Test with different queue names like `"mailers"`, `"exports"`, etc.

*   **Configuration Mocking in Tests:** You MUST mock the configuration to test different prefix values. Use RSpec's `allow` syntax:
    ```ruby
    before do
      allow(ActiveJob::Temporal.config).to receive(:task_queue_prefix).and_return("prod-")
    end
    ```
    This is the ONLY way to test different configuration values without actually changing global config.

*   **Code Style Requirements:**
    - Use double quotes for strings (not single quotes)
    - Use 2-space indentation
    - Add YARD documentation comments above the method
    - Use descriptive parameter names
    - Keep the method simple (should be ~5-8 lines total)

*   **Edge Cases to Handle:**
    - `job.queue_name` is `nil` → default to `"default"`
    - `job.queue_name` is an empty string `""` → treat as `nil`, default to `"default"`
    - `config.task_queue_prefix` is `nil` → no prefix
    - `config.task_queue_prefix` is empty string `""` → no prefix
    - Both queue_name and prefix are provided → concatenate properly

*   **Performance Note:** This method will be called on EVERY job enqueue, so keep it extremely fast. No complex logic, just simple string operations.

*   **Integration Context:** While you're only implementing a helper method now, understand that:
    - In I3.T1, this method will be called from `TemporalAdapter.enqueue(job)`
    - The returned task queue string will be passed to `client.start_workflow(task_queue: resolved_queue, ...)`
    - Workers must poll the SAME task queue name to pick up workflows
    - Task queue naming affects workflow routing and worker distribution

### Suggested Implementation Pattern

Your `lib/activejob/temporal/adapter.rb` should look like this after adding the new method:

```ruby
# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Adapter
      module_function

      # Builds a deterministic workflow ID from an ActiveJob instance
      # @param job [ActiveJob::Base] The job instance
      # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
      def build_workflow_id(job)
        "ajwf:#{job.class.name}:#{job.job_id}"
      end

      # Resolves the Temporal task queue name from an ActiveJob instance
      # @param job [ActiveJob::Base] The job instance
      # @return [String] Task queue name (optionally prefixed)
      def resolve_task_queue(job)
        queue_name = job.queue_name.to_s.strip
        queue_name = "default" if queue_name.empty?

        prefix = ActiveJob::Temporal.config.task_queue_prefix
        return queue_name if prefix.nil? || prefix.to_s.strip.empty?

        "#{prefix}#{queue_name}"
      end
    end
  end
end
```

### Suggested Test Structure

Your `spec/unit/adapter_spec.rb` should have a new describe block added:

```ruby
describe ".resolve_task_queue" do
  context "when no prefix is configured" do
    before do
      allow(ActiveJob::Temporal.config).to receive(:task_queue_prefix).and_return(nil)
    end

    it "returns the job's queue name" do
      job = SimpleJob.new
      job.queue_name = "billing"

      expect(described_class.resolve_task_queue(job)).to eq("billing")
    end

    it "returns 'default' when queue_name is nil" do
      job = SimpleJob.new
      job.queue_name = nil

      expect(described_class.resolve_task_queue(job)).to eq("default")
    end

    it "returns 'default' when queue_name is empty string" do
      job = SimpleJob.new
      job.queue_name = ""

      expect(described_class.resolve_task_queue(job)).to eq("default")
    end
  end

  context "when prefix is configured" do
    before do
      allow(ActiveJob::Temporal.config).to receive(:task_queue_prefix).and_return("prod-")
    end

    it "prepends prefix to job's queue name" do
      job = SimpleJob.new
      job.queue_name = "billing"

      expect(described_class.resolve_task_queue(job)).to eq("prod-billing")
    end

    it "prepends prefix to default queue" do
      job = SimpleJob.new
      job.queue_name = nil

      expect(described_class.resolve_task_queue(job)).to eq("prod-default")
    end

    it "works with different queue names" do
      job = SimpleJob.new
      job.queue_name = "mailers"

      expect(described_class.resolve_task_queue(job)).to eq("prod-mailers")
    end
  end

  context "when prefix is empty string" do
    before do
      allow(ActiveJob::Temporal.config).to receive(:task_queue_prefix).and_return("")
    end

    it "treats empty prefix as no prefix" do
      job = SimpleJob.new
      job.queue_name = "billing"

      expect(described_class.resolve_task_queue(job)).to eq("billing")
    end
  end
end
```

---

## 4. Summary & Next Steps

### What You're Building
A simple helper method that converts ActiveJob queue names to Temporal task queue names, with support for an optional global prefix from configuration.

### Key Requirements
1. **Method Signature**: `resolve_task_queue(job)` → returns `String`
2. **Logic**:
   - Extract `job.queue_name` (default to `"default"` if nil/empty)
   - Read `config.task_queue_prefix`
   - Prepend prefix if present and non-empty
   - Return final task queue string
3. **Testing**: Comprehensive tests covering all prefix/queue combinations
4. **Style**: Follow existing gem patterns (YARD docs, module_function, double quotes)

### Files to Modify
1. `lib/activejob/temporal/adapter.rb` - Add `resolve_task_queue` method after `build_workflow_id`
2. `spec/unit/adapter_spec.rb` - Add comprehensive test suite in new describe block

### Files to Read (for context)
1. `lib/activejob/temporal.rb` - To understand configuration structure
2. `spec/fixtures/sample_jobs.rb` - To use proper test job classes

### Success Criteria
✓ Add `resolve_task_queue(job)` method to adapter.rb
✓ Method returns correct task queue for all scenarios
✓ Tests cover: no prefix, with prefix, nil queue, explicit queue, empty strings
✓ Configuration is properly mocked in tests
✓ All tests pass (`rake spec`)
✓ Code passes style checks (`rake rubocop`)
✓ YARD documentation is complete and clear

### Example Expected Behavior
```ruby
# No prefix configured
job.queue_name = "billing"
resolve_task_queue(job) # => "billing"

# Prefix configured as "prod-"
job.queue_name = "billing"
resolve_task_queue(job) # => "prod-billing"

# Nil queue name, no prefix
job.queue_name = nil
resolve_task_queue(job) # => "default"

# Nil queue name, with prefix
job.queue_name = nil
config.task_queue_prefix = "staging-"
resolve_task_queue(job) # => "staging-default"
```
