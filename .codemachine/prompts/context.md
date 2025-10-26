# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I1.T5",
  "iteration_id": "I1",
  "iteration_goal": "Establish project structure, dependencies, and foundational modules (configuration, client, payload handling). Generate core architecture diagrams.",
  "description": "Create `lib/activejob/temporal/payload.rb` with methods for serializing and deserializing ActiveJob arguments. Implement `Payload.from_job(job, scheduled_at: nil)` method that extracts job class name, job_id, queue_name, arguments (using ActiveJob::Arguments.serialize), scheduled_at timestamp (ISO8601 format if present), executions, and exception_executions. Return a hash suitable for JSON serialization. Implement `Payload.deserialize_args(payload)` method that converts the arguments array back to Ruby objects (using ActiveJob::Arguments.deserialize). Enforce 250KB payload size limit: raise `ActiveJob::SerializationError` if JSON-serialized payload exceeds 250KB (configurable via `config.max_payload_size_kb`, default 250). Write unit tests in `spec/unit/payload_spec.rb` covering: round-trip serialization (job → payload → args), GlobalID support (ActiveRecord models), payload size limit enforcement, error handling for non-serializable objects. Create JSON Schema for payload structure in `api/job_payload_schema.json` (Draft 07) defining required fields (job_class, job_id, queue_name, arguments) and optional fields (scheduled_at, executions, exception_executions).",
  "agent_type_hint": "BackendAgent",
  "inputs": "Section 2 (Core Architecture - Data Model Overview), Section 3.6 (Job Payload structure), ActiveJob::Arguments documentation, JSON Schema Draft 07 specification",
  "target_files": [
    "lib/activejob/temporal/payload.rb",
    "spec/unit/payload_spec.rb",
    "api/job_payload_schema.json",
    "spec/fixtures/sample_jobs.rb"
  ],
  "input_files": [],
  "deliverables": "Working payload serializer/deserializer, passing unit tests (100% coverage), JSON Schema for payload validation, sample jobs for testing",
  "acceptance_criteria": "`Payload.from_job(job)` returns a hash with keys: `job_class`, `job_id`, `queue_name`, `arguments`, `executions`, `exception_executions`; `Payload.from_job(job, scheduled_at: timestamp)` includes `scheduled_at` in ISO8601 format; `Payload.deserialize_args(payload)` correctly converts arguments back to Ruby objects; Round-trip test: `Payload.deserialize_args(Payload.from_job(job))` returns original arguments; GlobalID test: Passing an ActiveRecord model as argument serializes to GlobalID string and deserializes back to model (requires stubbing/mocking AR model in tests); Payload size limit: Serializing a job with >250KB arguments raises `ActiveJob::SerializationError` with descriptive message; Non-serializable objects (e.g., Proc, Thread) raise `ActiveJob::SerializationError`; `api/job_payload_schema.json` validates against JSON Schema Draft 07 meta-schema; JSON Schema includes all required and optional fields with correct types (string, integer, array, object); `rake spec` passes for payload_spec.rb; Code passes `rake rubocop`",
  "dependencies": [
    "I1.T1"
  ],
  "parallelizable": true,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: Data Model Overview (from Architecture Blueprint - Section 3.6)

Based on the task inputs referencing "Section 2 (Core Architecture - Data Model Overview)" and "Section 3.6 (Job Payload structure)", the Payload module is responsible for serializing ActiveJob job instances into Temporal-compatible data structures. The core data entities are:

**Job Payload Structure:**
- **job_class** (string, required): Fully-qualified class name of the ActiveJob (e.g., "SendInvoiceJob")
- **job_id** (string, required): Unique identifier for the job instance (UUID)
- **queue_name** (string, required): ActiveJob queue name (e.g., "default", "mailers", "critical")
- **arguments** (array, required): Serialized job arguments using ActiveJob::Arguments.serialize
- **executions** (integer, optional): Number of times this job has been executed (for retry tracking)
- **exception_executions** (hash, optional): Hash mapping exception class names to execution counts
- **scheduled_at** (string, optional): ISO8601 timestamp for delayed jobs (e.g., "2025-10-26T15:30:00Z")

**Key Design Decisions:**
1. **Payload Size Limit**: 250KB enforced to prevent Temporal workflow history bloat. This is configurable via `config.max_payload_size_kb`.
2. **GlobalID Support**: ActiveRecord models and other GlobalID-compatible objects must serialize to GlobalID strings and deserialize back to objects.
3. **ActiveJob::Arguments**: Leverage Rails' built-in serialization for consistency with other ActiveJob adapters (Sidekiq, Resque, etc.).
4. **Error Handling**: Non-serializable objects (Proc, Thread, IO) must raise descriptive `ActiveJob::SerializationError` exceptions.

### Context: Serialization Format (from Technology Stack)

**Serialization Stack:**
- **Primary Format**: JSON (for Temporal workflow inputs)
- **ActiveJob Compatibility**: Use `ActiveJob::Arguments.serialize` and `ActiveJob::Arguments.deserialize` for argument encoding
- **GlobalID**: Automatically handled by ActiveJob::Arguments for ActiveRecord models
- **Custom Types**: ActiveJob serializers support BigDecimal, Date, DateTime, Symbol, Range, etc.

**Why JSON?**
- Temporal stores workflow inputs in event history, which must be human-readable for debugging
- JSON is language-agnostic, enabling potential polyglot worker support in the future
- ActiveJob::Arguments already outputs JSON-compatible structures

### Context: Payload Validation (from Non-Functional Requirements)

**Security & Performance Requirements:**
1. **Payload Size Limit (250KB)**:
   - Prevents denial-of-service via large payloads
   - Protects Temporal cluster performance (event history storage)
   - Configurable via `config.max_payload_size_kb` for power users

2. **Safe Serialization**:
   - Only serialize whitelisted types (String, Integer, Float, Array, Hash, GlobalID objects)
   - Block dangerous types (Proc, Thread, IO, File)
   - Raise `ActiveJob::SerializationError` with clear messages

3. **Round-Trip Consistency**:
   - `deserialize_args(from_job(job))` must return original arguments
   - GlobalID references must resolve correctly (requires object reloading from database)

### Context: Configuration from I1.T3

The Configuration class in `lib/activejob/temporal.rb` has these attributes (YOU MUST ADD `max_payload_size_kb` to this list):
- `target` (default: `"127.0.0.1:7233"`)
- `namespace` (default: `"default"`)
- `task_queue_prefix` (default: `nil`)
- `default_activity_timeout` (default: `15.minutes`)
- `default_retry_initial_interval` (default: `30.seconds`)
- `default_retry_backoff` (default: `2.0`)
- `default_retry_max_attempts` (default: `1`)
- `logger` (default: `Rails.logger` or `Logger.new($stdout)`)
- `enable_tracing` (default: `true`)
- **max_payload_size_kb** (MUST BE ADDED, default: `250`) - NEW ATTRIBUTE REQUIRED FOR THIS TASK

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** This is the main entrypoint for the gem. It defines the `ActiveJob::Temporal` module with a `Configuration` class and memoized `config` singleton. It also defines the `Error` base exception class.
    *   **Recommendation:** You MUST add `max_payload_size_kb` attribute to the `Configuration` class. Add it to the `attr_accessor` list at line 14 and set default value `@max_payload_size_kb = 250` in the `initialize` method at line 24.
    *   **Key Observations:**
      - Configuration already exists with attributes like `logger`, `default_activity_timeout`, etc.
      - The module structure is `ActiveJob::Temporal::*`, so your Payload module will be `ActiveJob::Temporal::Payload`
      - The configuration system uses a DSL pattern with `configure { |config| ... }`
      - You'll need to add `require_relative "temporal/payload"` near line 7 after `require_relative "temporal/client"`

*   **File:** `lib/activejob/temporal/client.rb`
    *   **Summary:** Implements the Temporal client connection wrapper with TLS support and error handling.
    *   **Recommendation:** You SHOULD follow the same pattern for error handling: wrap exceptions and re-raise with descriptive messages. Notice how it uses `format()` for error message interpolation.
    *   **Code Pattern Example:**
      ```ruby
      rescue StandardError => e
        raise ActiveJob::Temporal::Error,
              format("Unable to connect to Temporal at %<target>s: %<error>s", ...)
      end
      ```
    *   **Note:** For payload serialization errors, use `ActiveJob::SerializationError` (Rails built-in), NOT `ActiveJob::Temporal::Error`.

*   **File:** `spec/unit/configuration_spec.rb` and `spec/unit/client_spec.rb`
    *   **Summary:** These spec files demonstrate the testing patterns used in this project.
    *   **Recommendation:** You SHOULD follow these conventions:
      - Use `described_class` instead of hardcoding class names
      - Use `before` blocks to reset state
      - Use RSpec's `let` for test data setup
      - Mock external dependencies (e.g., `ActiveJob::Arguments.serialize`)
      - Test both success and error paths
      - Group tests with `describe` blocks by method name

*   **File:** `activejob-temporal.gemspec`
    *   **Summary:** Gemspec declares dependencies including `activejob >= 6.1` and `globalid >= 0.3`.
    *   **Recommendation:** You CAN safely use `ActiveJob::Arguments` and `GlobalID` classes - they're already dependencies. No need to add conditional requires.
    *   **Note:** The gemspec includes `activejob` as a dependency, so all ActiveJob classes are available.

*   **File:** `docs/configuration_reference.md`
    *   **Summary:** Documents all configuration options with descriptions, types, defaults, and examples.
    *   **Recommendation:** You MUST update this file to add documentation for the new `max_payload_size_kb` configuration option. Add it to the table at line 8 and provide a usage example.

### Implementation Tips & Notes

*   **Tip:** ActiveJob::Arguments is part of Rails' ActiveJob framework and handles serialization of complex types (GlobalID, BigDecimal, Date, etc.). You SHOULD use it instead of writing custom serialization logic.
    - Use `ActiveJob::Arguments.serialize(args_array)` to serialize
    - Use `ActiveJob::Arguments.deserialize(serialized_array)` to deserialize

*   **Tip:** For the 250KB payload size check, you should:
    1. Serialize the entire payload hash to JSON: `json_str = JSON.generate(payload)`
    2. Check byte size: `json_str.bytesize`
    3. Get limit from config: `ActiveJob::Temporal.config.max_payload_size_kb * 1024`
    4. Raise `ActiveJob::SerializationError` if `json_str.bytesize > limit`

*   **Note:** The task requires creating `spec/fixtures/sample_jobs.rb` for test fixtures. You SHOULD define simple job classes here like:
    ```ruby
    # frozen_string_literal: true

    # Mock ApplicationJob since we don't have full Rails in gem tests
    unless defined?(ApplicationJob)
      class ApplicationJob
        attr_accessor :job_id, :queue_name, :arguments, :executions, :exception_executions

        def initialize(args = [])
          @job_id = SecureRandom.uuid
          @queue_name = "default"
          @arguments = args
          @executions = 0
          @exception_executions = {}
        end

        def self.name
          self.to_s
        end
      end
    end

    class SimpleJob < ApplicationJob
      def perform(*args); end
    end

    class ScheduledJob < ApplicationJob
      def perform(*args); end
    end
    ```

*   **Note:** For JSON Schema creation (`api/job_payload_schema.json`), you should use JSON Schema Draft 07 format:
    ```json
    {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "title": "ActiveJob Temporal Payload Schema",
      "type": "object",
      "required": ["job_class", "job_id", "queue_name", "arguments"],
      "properties": {
        "job_class": { "type": "string" },
        "job_id": { "type": "string" },
        "queue_name": { "type": "string" },
        "arguments": { "type": "array" },
        "executions": { "type": "integer" },
        "exception_executions": { "type": "object" },
        "scheduled_at": { "type": "string", "format": "date-time" }
      }
    }
    ```

*   **Warning:** The task mentions ISO8601 format for `scheduled_at`. Ruby's `Time#iso8601` method will give you this. Make sure to handle nil values properly (only include `scheduled_at` key if timestamp is provided).

*   **Warning:** ActiveJob's `executions` and `exception_executions` are internal attributes. Extract them from the job instance like:
    ```ruby
    executions: job.executions || 0,
    exception_executions: job.exception_executions || {}
    ```

*   **Critical:** For GlobalID support in tests, you CANNOT use real ActiveRecord models (no database in gem tests). You SHOULD:
    1. Create a mock object that responds to `to_global_id` and returns a mock GlobalID
    2. Mock `ActiveJob::Arguments.serialize` to return a structure with GlobalID strings
    3. Mock `ActiveJob::Arguments.deserialize` to resolve GlobalID strings back to mock objects
    4. This simulates the round-trip without database dependencies

### Required Changes Summary

**1. Add Configuration Attribute** (`lib/activejob/temporal.rb`):
```ruby
# In Configuration class, line 14:
attr_accessor :target,
              :namespace,
              :task_queue_prefix,
              :default_retry_backoff,
              :default_retry_max_attempts,
              :logger,
              :enable_tracing,
              :max_payload_size_kb  # ADD THIS

# In initialize method, around line 32:
@max_payload_size_kb = 250  # ADD THIS
```

**2. Add Require Statement** (`lib/activejob/temporal.rb`):
```ruby
# Around line 7, after require_relative "temporal/client":
require_relative "temporal/payload"  # ADD THIS
```

**3. Update Documentation** (`docs/configuration_reference.md`):
Add row to table at line 8:
```markdown
| `max_payload_size_kb` | Integer | `250` | Maximum allowed payload size in kilobytes. Prevents DoS via large payloads. |
```

### Testing Strategy

1. **Unit Test Structure** (`spec/unit/payload_spec.rb`):
   - `describe Payload.from_job` - test serialization
   - `describe Payload.deserialize_args` - test deserialization
   - Round-trip tests that combine both methods
   - Payload size limit enforcement
   - Error handling for non-serializable objects

2. **Mocking Strategy:**
   - Mock `ActiveJob::Arguments.serialize` to return predictable output
   - Mock `ActiveJob::Arguments.deserialize` to reverse the transformation
   - Mock `JSON.generate` to simulate large payloads for size limit tests
   - Create mock job objects with required attributes

3. **Coverage Requirements:**
   - 100% code coverage required
   - Test all branches (with/without scheduled_at, with/without executions, etc.)
   - Test error paths (oversized payload, non-serializable objects)

### Recommended Implementation Approach

1. **First:** Update `lib/activejob/temporal.rb` to add `max_payload_size_kb` configuration attribute
2. **Second:** Create `lib/activejob/temporal/payload.rb` with `Payload` module and methods
3. **Third:** Create `api/job_payload_schema.json` with JSON Schema Draft 07 structure
4. **Fourth:** Create `spec/fixtures/sample_jobs.rb` with mock job classes
5. **Fifth:** Write comprehensive unit tests in `spec/unit/payload_spec.rb`
6. **Sixth:** Update `docs/configuration_reference.md` to document new configuration option
7. **Seventh:** Run `bundle exec rake spec` and ensure all tests pass
8. **Eighth:** Run `bundle exec rake rubocop` and fix any style violations

---

## 4. Acceptance Checklist

Before marking this task complete, verify ALL of the following:

### Configuration Changes
- [ ] `lib/activejob/temporal.rb` updated: `max_payload_size_kb` added to `attr_accessor` list
- [ ] `lib/activejob/temporal.rb` updated: `@max_payload_size_kb = 250` added to `initialize` method
- [ ] `lib/activejob/temporal.rb` updated: `require_relative "temporal/payload"` added after client require
- [ ] `docs/configuration_reference.md` updated: New row added to configuration table for `max_payload_size_kb`

### Payload Module Implementation
- [ ] `lib/activejob/temporal/payload.rb` exists with frozen string literal
- [ ] `Payload` module defined under `ActiveJob::Temporal::Payload`
- [ ] `Payload.from_job(job)` method implemented and returns hash with required keys: `job_class`, `job_id`, `queue_name`, `arguments`, `executions`, `exception_executions`
- [ ] `Payload.from_job(job, scheduled_at: timestamp)` includes `scheduled_at` in ISO8601 format
- [ ] `Payload.deserialize_args(payload)` method implemented and correctly deserializes arguments
- [ ] Payload size limit enforced: raises `ActiveJob::SerializationError` for >250KB payloads
- [ ] Payload size check uses `ActiveJob::Temporal.config.max_payload_size_kb` configuration value

### JSON Schema
- [ ] `api/job_payload_schema.json` exists
- [ ] Schema uses JSON Schema Draft 07 (`"$schema": "http://json-schema.org/draft-07/schema#"`)
- [ ] Required fields defined: `job_class`, `job_id`, `queue_name`, `arguments`
- [ ] Optional fields defined: `scheduled_at`, `executions`, `exception_executions`
- [ ] All fields have correct types (string, integer, array, object)
- [ ] `scheduled_at` has `"format": "date-time"` constraint

### Test Fixtures
- [ ] `spec/fixtures/sample_jobs.rb` exists
- [ ] Mock `ApplicationJob` class defined
- [ ] At least two sample job classes defined (e.g., `SimpleJob`, `ScheduledJob`)
- [ ] Sample jobs have required attributes: `job_id`, `queue_name`, `arguments`, `executions`, `exception_executions`

### Unit Tests
- [ ] `spec/unit/payload_spec.rb` exists with frozen string literal
- [ ] Tests for `Payload.from_job` cover all required keys in returned hash
- [ ] Tests for `Payload.from_job` with `scheduled_at` parameter verify ISO8601 format
- [ ] Tests for `Payload.deserialize_args` verify correct deserialization
- [ ] Round-trip test: original arguments == deserialized arguments
- [ ] GlobalID test passes (with mocking, no real database required)
- [ ] Payload size limit test raises `ActiveJob::SerializationError` for >250KB
- [ ] Payload size limit test uses configurable `max_payload_size_kb` value
- [ ] Non-serializable objects (Proc, Thread) raise `ActiveJob::SerializationError`
- [ ] All tests use proper mocking for `ActiveJob::Arguments.serialize` and `deserialize`
- [ ] Tests follow project conventions (use `described_class`, `before` blocks, etc.)

### Quality Checks
- [ ] `rake spec` passes for payload_spec.rb (zero failures)
- [ ] SimpleCov reports 100% coverage for `lib/activejob/temporal/payload.rb`
- [ ] `rake rubocop` passes (zero offenses)
- [ ] All files start with `# frozen_string_literal: true`
- [ ] Code follows existing project patterns and conventions

### Integration Checks
- [ ] `require 'activejob-temporal'` successfully loads the payload module
- [ ] Configuration option `max_payload_size_kb` is accessible via `ActiveJob::Temporal.config.max_payload_size_kb`
- [ ] Default value for `max_payload_size_kb` is 250
- [ ] Can configure `max_payload_size_kb` via `ActiveJob::Temporal.configure { |c| c.max_payload_size_kb = 500 }`
