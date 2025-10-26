# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I1.T8",
  "iteration_id": "I1",
  "iteration_goal": "Establish project structure, dependencies, and foundational modules (configuration, client, payload handling). Generate core architecture diagrams.",
  "description": "Create `lib/activejob/temporal/logger.rb` with a structured logging helper. Implement `Logger.log_event(event_name, attributes = {})` method that writes JSON-formatted logs to `ActiveJob::Temporal.config.logger`. Include standard attributes in every log: `event` (event_name), `timestamp` (ISO8601), plus any custom attributes passed. Support log levels: `info`, `warn`, `error`. If `semantic_logger` gem is available, use it; otherwise fall back to standard Ruby Logger with manual JSON formatting. Write unit tests in `spec/unit/logger_spec.rb` covering: log output format (JSON), standard attributes presence, custom attributes, different log levels. This is a helper module used by other components, so extensive testing is not required (basic coverage is sufficient).",
  "agent_type_hint": "BackendAgent",
  "inputs": "Section 3.8.2 (Logging Strategy), semantic_logger gem documentation (optional), Ruby Logger documentation",
  "target_files": [
    "lib/activejob/temporal/logger.rb",
    "spec/unit/logger_spec.rb"
  ],
  "input_files": [
    "lib/activejob/temporal.rb"
  ],
  "deliverables": "Working logger helper, passing unit tests (basic coverage), support for JSON-formatted logs",
  "acceptance_criteria": "`Logger.log_event(\"workflow_enqueued\", {workflow_id: \"abc123\"})` writes a JSON log line to configured logger; Log includes: `{\"event\": \"workflow_enqueued\", \"timestamp\": \"2025-10-25T12:00:00Z\", \"workflow_id\": \"abc123\"}`; Supports log levels: `Logger.info(event, attrs)`, `Logger.warn(event, attrs)`, `Logger.error(event, attrs)`; If `semantic_logger` is available (detected via `defined?(SemanticLogger)`), use it; otherwise use stdlib Logger; Unit tests verify JSON structure and attribute presence (use StringIO or similar to capture log output); `rake spec` passes for logger_spec.rb; Code passes `rake rubocop`",
  "dependencies": ["I1.T3"],
  "parallelizable": true,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: Logging Strategy (from 05_Operational_Architecture.md)

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

### Context: Task I1.T8 Details (from 02_Iteration_I1.md)

```markdown
*   **Task 1.8: Implement Logger Helper**
    *   **Task ID:** `I1.T8`
    *   **Description:** Create `lib/activejob/temporal/logger.rb` with a structured logging helper. Implement `Logger.log_event(event_name, attributes = {})` method that writes JSON-formatted logs to `ActiveJob::Temporal.config.logger`. Include standard attributes in every log: `event` (event_name), `timestamp` (ISO8601), plus any custom attributes passed. Support log levels: `info`, `warn`, `error`. If `semantic_logger` gem is available, use it; otherwise fall back to standard Ruby Logger with manual JSON formatting. Write unit tests in `spec/unit/logger_spec.rb` covering: log output format (JSON), standard attributes presence, custom attributes, different log levels. This is a helper module used by other components, so extensive testing is not required (basic coverage is sufficient).
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 3.8.2 (Logging Strategy), semantic_logger gem documentation (optional), Ruby Logger documentation
    *   **Input Files:**
        - `lib/activejob/temporal.rb`
    *   **Target Files:**
        - `lib/activejob/temporal/logger.rb`
        - `spec/unit/logger_spec.rb`
    *   **Deliverables:** Working logger helper, passing unit tests (basic coverage), support for JSON-formatted logs
    *   **Acceptance Criteria:**
        - `Logger.log_event("workflow_enqueued", {workflow_id: "abc123"})` writes a JSON log line to configured logger
        - Log includes: `{"event": "workflow_enqueued", "timestamp": "2025-10-25T12:00:00Z", "workflow_id": "abc123"}`
        - Supports log levels: `Logger.info(event, attrs)`, `Logger.warn(event, attrs)`, `Logger.error(event, attrs)`
        - If `semantic_logger` is available (detected via `defined?(SemanticLogger)`), use it; otherwise use stdlib Logger
        - Unit tests verify JSON structure and attribute presence (use StringIO or similar to capture log output)
        - `rake spec` passes for logger_spec.rb
        - Code passes `rake rubocop`
    *   **Dependencies:** I1.T3 (configuration module must exist for logger reference)
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** This is the main entry point module defining the `ActiveJob::Temporal` namespace. It contains the `Configuration` class with logging configuration already set up (`config.logger` defaults to `Rails.logger` if available, otherwise `Logger.new($stdout)`).
    *   **Recommendation:** Your logger module MUST use `ActiveJob::Temporal.config.logger` to write logs. This is already available and configured.
    *   **Key Detail:** The configuration module uses `attr_accessor :logger` and initializes it via the `default_logger` private method at lines 60-66.

*   **File:** `lib/activejob/temporal/payload.rb`
    *   **Summary:** This file implements the `Payload` module using `extend self` pattern (module-level methods). It follows the pattern: freeze string literals, require dependencies at top, module body with public methods first, then private methods.
    *   **Recommendation:** You SHOULD follow the same module structure pattern for consistency:
        - Start with `# frozen_string_literal: true`
        - Require necessary dependencies (`json`, `time`)
        - Use `module Payload; extend self` pattern for module-level methods
        - Place public methods first, private methods last

*   **File:** `spec/unit/configuration_spec.rb`
    *   **Summary:** This test demonstrates the project's RSpec testing patterns and conventions.
    *   **Recommendation:** Follow these testing patterns:
        - Use `# frozen_string_literal: true` at the top
        - Use `require "spec_helper"`
        - Use `RSpec.describe` with the module/class name
        - Use `before` blocks to reset state (e.g., clearing instance variables)
        - Use clear descriptive test names with `it "does something specific"`
        - Use `expect(...).to` syntax (not `should`)
        - Use `double(:logger)` or `instance_double` for mocking

*   **File:** `spec/spec_helper.rb`
    *   **Summary:** Configures RSpec with SimpleCov for coverage tracking. Coverage must be enabled with branch coverage.
    *   **Recommendation:** No changes needed. Your tests will automatically be included in coverage reporting.

*   **File:** `activejob-temporal.gemspec`
    *   **Summary:** Lists all dependencies. `semantic_logger` is NOT included as a dependency (neither runtime nor development).
    *   **Recommendation:** Since `semantic_logger` is not a dependency, your implementation MUST gracefully detect its absence and fall back to standard Ruby Logger. Use `defined?(SemanticLogger)` to check availability.

### Implementation Tips & Notes

*   **Tip 1: Module Pattern**
    - All existing modules in this project use the `module X; extend self` pattern for module-level methods.
    - This allows calling methods like `Payload.from_job(...)` instead of instance methods.
    - You SHOULD follow this pattern for `Logger` module.

*   **Tip 2: JSON Formatting**
    - When using standard Ruby Logger (fallback case), you need to manually format logs as JSON.
    - Use `require "json"` and `JSON.generate(hash)` to create JSON strings.
    - The logger's formatter should be set to output the JSON directly without adding extra formatting.

*   **Tip 3: Timestamp Format**
    - Use ISO8601 format for timestamps: `Time.now.utc.iso8601`
    - This is consistent with the `Payload.iso8601_timestamp` method already implemented.

*   **Tip 4: Logger Access**
    - The configured logger is available via `ActiveJob::Temporal.config.logger`
    - This returns either `Rails.logger` (if Rails is present) or a standard `Logger.new($stdout)`
    - Your module should delegate to this configured logger instance.

*   **Tip 5: Testing with StringIO**
    - To test log output without polluting STDOUT, use `StringIO`:
      ```ruby
      string_io = StringIO.new
      logger = Logger.new(string_io)
      # ... configure and use logger ...
      output = string_io.string
      ```
    - Parse the JSON output and verify attributes are present.

*   **Tip 6: Log Levels**
    - Standard Ruby Logger supports: `debug`, `info`, `warn`, `error`, `fatal`
    - The task requires supporting: `info`, `warn`, `error`
    - You can implement methods like `Logger.info(event, attrs)`, `Logger.warn(event, attrs)`, `Logger.error(event, attrs)`
    - Or use a single `log_event(event, attrs, level: :info)` method with level parameter.

*   **Note 1: semantic_logger Detection**
    - `semantic_logger` is NOT a declared dependency, so it will typically NOT be available in tests.
    - Your implementation should have two code paths:
      1. If `defined?(SemanticLogger)` returns truthy: use semantic_logger
      2. Otherwise: use standard Logger with manual JSON formatting
    - Your tests should primarily test the fallback path (standard Logger) since that's what will be loaded.

*   **Note 2: Required Files in lib/activejob/temporal.rb**
    - After creating `logger.rb`, you MUST add `require_relative "temporal/logger"` to `lib/activejob/temporal.rb`
    - Current file requires: version, client, payload, search_attributes, retry_mapper
    - Add logger to this list (probably after line 10, before or after retry_mapper)

*   **Warning: Don't Modify Configuration**
    - The `Configuration` class already has the `logger` attribute properly configured.
    - You should NOT modify the configuration class.
    - Only create the new `Logger` module that uses the configured logger.

*   **Note 3: Frozen String Literals**
    - ALL Ruby files in this project start with `# frozen_string_literal: true`
    - This is enforced by Rubocop and improves performance.
    - You MUST include this at the top of both implementation and test files.

### Implementation Strategy

Based on the codebase patterns, here's the recommended implementation approach:

1. **Create `lib/activejob/temporal/logger.rb`:**
   - Start with frozen string literal pragma
   - Require `json` and `time`
   - Define module `ActiveJob::Temporal::Logger` with `extend self`
   - Implement public methods: `info(event, attrs)`, `warn(event, attrs)`, `error(event, attrs)`
   - These should call a private `log_event(event, attrs, level)` method
   - The private method should:
     - Build a hash with `event`, `timestamp` (ISO8601), and merge custom attrs
     - Check if SemanticLogger is available
     - If yes: use semantic logger (you may need to research the API)
     - If no: use `ActiveJob::Temporal.config.logger` with manual JSON formatting

2. **Update `lib/activejob/temporal.rb`:**
   - Add `require_relative "temporal/logger"` after existing requires

3. **Create `spec/unit/logger_spec.rb`:**
   - Follow the RSpec patterns from existing specs
   - Test with StringIO to capture log output
   - Verify JSON structure and attributes
   - Test all three log levels
   - Test with and without custom attributes
   - Consider testing both semantic_logger (if you mock it) and fallback Logger paths

4. **Run Quality Checks:**
   - Run `rake rubocop` and fix any style issues
   - Run `rake spec` to ensure tests pass
   - Verify coverage is adequate (SimpleCov will report)

### Code Structure Template

Based on existing patterns, your logger module should look something like this structure:

```ruby
# frozen_string_literal: true

require "json"
require "time"

module ActiveJob
  module Temporal
    module Logger
      extend self

      def info(event, attributes = {})
        log_event(event, attributes, :info)
      end

      def warn(event, attributes = {})
        log_event(event, attributes, :warn)
      end

      def error(event, attributes = {})
        log_event(event, attributes, :error)
      end

      private

      def log_event(event, attributes, level)
        # Build log payload with standard attributes
        # Check for SemanticLogger
        # If available: use it
        # Otherwise: use ActiveJob::Temporal.config.logger with JSON
      end
    end
  end
end
```

This structure matches the existing module patterns in the codebase and will integrate seamlessly with the rest of the system.
