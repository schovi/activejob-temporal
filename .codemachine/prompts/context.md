# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I6.T2",
  "iteration_id": "I6",
  "iteration_goal": "Enhance Version 2 with robust validation, better error handling, and comprehensive documentation from Version 1 analysis while maintaining Version 2's superior architecture.",
  "description": "Add optional configuration attributes to the Configuration class for production flexibility: `identity` (worker identity string for observability, default: nil), `max_payload_size_kb` (explicit payload size limit in kilobytes, default: 250). Optionally add environment variable defaults for 12-factor app compliance by reading from ENV in the initialize method: `target` from ENV['TEMPORAL_TARGET'] || '127.0.0.1:7233', `namespace` from ENV['TEMPORAL_NAMESPACE'] || 'default', `task_queue_prefix` from ENV['TEMPORAL_TASK_QUEUE_PREFIX'] || nil, `max_payload_size_kb` from ENV['TEMPORAL_MAX_PAYLOAD_SIZE_KB'] || 250. Document these new options in existing `docs/configuration_reference.md` with descriptions, types, defaults, usage examples, and environment variable mappings. Update unit tests to verify new attributes are accessible and environment variable precedence works correctly.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Version 1 lib/active_job/temporal/configuration.rb:32-65 (env var patterns), Version 2 existing Configuration class, docs/configuration_reference.md",
  "target_files": [
    "lib/activejob/temporal.rb",
    "docs/configuration_reference.md",
    "spec/unit/configuration_spec.rb"
  ],
  "input_files": [
    "lib/activejob/temporal.rb",
    "docs/configuration_reference.md",
    "spec/unit/configuration_spec.rb"
  ],
  "deliverables": "Enhanced Configuration class with identity and max_payload_size_kb attributes, environment variable support, updated documentation",
  "acceptance_criteria": "Configuration class has `identity` attr_accessor (default: nil); Configuration class has `max_payload_size_kb` attr_accessor (default: 250); Configuration initialize reads from ENV['TEMPORAL_TARGET'], ENV['TEMPORAL_NAMESPACE'], ENV['TEMPORAL_TASK_QUEUE_PREFIX'], ENV['TEMPORAL_MAX_PAYLOAD_SIZE_KB'] with appropriate defaults; Setting ENV['TEMPORAL_TARGET']='custom:9999' before config creation sets config.target to 'custom:9999'; docs/configuration_reference.md includes new section documenting `identity` and `max_payload_size_kb` with types, defaults, usage examples; docs/configuration_reference.md includes table mapping environment variables to config attributes; Unit tests verify: default values, environment variable precedence, attribute read/write; `rake spec` passes; `rake rubocop` passes",
  "dependencies": ["I6.T1"],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: nfr-observability (from 01_Context_and_Drivers.md)

```markdown
## Observability

- **Logging**: All adapter operations (enqueue, cancellation, errors) must emit structured logs (JSON format recommended) to Rails' configured logger
- **Metrics**: Adapter should expose metrics about job enqueue rates, workflow execution counts, and failure rates (optional for v0.1, but architecture should allow future instrumentation)
- **Tracing**: Integration with OpenTelemetry distributed tracing is highly desirable for production deployments
- **Search and Filter**: Jobs must be searchable in Temporal UI by job class, queue name, job ID, enqueue time, and (optionally) tenant ID
```

### Context: technological-constraints (from 01_Context_and_Drivers.md)

```markdown
## Technological Constraints

- **Ruby Version**: Gem must support Ruby >= 3.2 (to align with Temporal Ruby SDK requirements and modern Rails versions)
- **Rails Version**: ActiveJob integration requires Rails >= 6.1 (first version with `enqueue_after_transaction_commit?` support)
- **Temporal Ruby SDK**: Must use the official `temporalio` gem (currently in GA as of late 2024)
- **Serialization**: Job arguments must be serializable by ActiveJob's serializer (supports GlobalID, JSON-compatible types, custom serializers)
- **No C Extensions**: Prefer pure Ruby implementation where possible to maximize portability
```

### Context: deployment-constraints (from 01_Context_and_Drivers.md)

```markdown
## Deployment Constraints

- **Worker Deployment**: Users must run a separate worker process (using `Temporalio::Worker`) alongside their Rails application. This worker polls Temporal for tasks and executes activities in a long-running Ruby process
- **Temporal Server Access**: Workers and Rails application servers must have network access to a Temporal cluster (on-premises or Temporal Cloud)
- **No Database Polling**: Unlike traditional queue adapters (e.g., Delayed Job, Que), this adapter does NOT poll a database—Temporal handles all workflow state persistence
- **Transaction Boundaries**: Job enqueue must respect Rails transaction boundaries (deferred enqueue after commit via `enqueue_after_transaction_commit?`)
```

### Context: design-preferences (from 01_Context_and_Drivers.md)

```markdown
## Design Preferences

- **Explicitness Over Magic**: Favor explicit configuration and clear method signatures over implicit behavior or "convention over configuration"
- **Fail-Fast**: Prefer early validation errors (e.g., invalid configuration) over runtime surprises
- **Rails Conventions**: Where applicable, follow Rails idioms (e.g., use Rails logger, respect ActiveJob callbacks, integrate with Rails test helpers)
- **Minimal Dependencies**: Keep runtime dependencies minimal—only require gems that are strictly necessary for core functionality
```

### Context: technology-stack (from 01_Plan_Overview_and_Setup.md)

```markdown
## Technology Stack

### Core Technologies
- **Ruby**: >= 3.2 (matches Temporal SDK requirement, supports modern syntax and performance)
- **Rails**: >= 6.1 (first version with `enqueue_after_transaction_commit?` support; tested up to Rails 7.x)
- **Temporal Ruby SDK**: `temporalio` gem (GA version; wraps Temporal's gRPC API with Ruby workflow/activity DSL)

### Dependencies
- **Required**:
  - `activejob` (>= 6.1) — for ActiveJob adapter interface
  - `globalid` — for serializing ActiveRecord models and other GlobalID-compatible objects
  - `temporalio` — Temporal Ruby SDK
- **Optional**:
  - `semantic_logger` — for structured JSON logging (falls back to stdlib Logger if unavailable)
  - `opentelemetry-sdk` — for distributed tracing (if `enable_tracing` is true)

### Serialization Formats
- **Job Payloads**: JSON (via `ActiveJob::Arguments.serialize/deserialize`)
- **Workflow Metadata**: Temporal Search Attributes (keywords, datetime, integers)
- **Retry Policies**: Temporal `RetryPolicy` hash (converted from ActiveJob `retry_on`/`discard_on` DSL)
```

### Context: data-model-overview (from 01_Plan_Overview_and_Setup.md)

```markdown
## Data Model Overview

The adapter does not persist job state to a local database. All state is stored in Temporal's internal database. The logical data model for jobs includes:

1. **Job Payload** (Temporal Workflow Input):
   - `job_class`: String (e.g., "SendInvoiceJob")
   - `job_id`: String (UUID generated by ActiveJob)
   - `queue_name`: String (e.g., "billing")
   - `arguments`: Array (serialized via ActiveJob::Arguments)
   - `scheduled_at`: ISO8601 timestamp (optional, for scheduled jobs)
   - `executions`: Integer (retry count; incremented by activity retries)
   - `exception_executions`: Hash (for tracking which exceptions caused retries)

2. **Workflow Metadata** (Temporal Search Attributes):
   - `ajClass`: Keyword (job class name for filtering)
   - `ajQueue`: Keyword (queue name)
   - `ajJobId`: Keyword (job ID for correlation)
   - `ajEnqueuedAt`: Datetime (enqueue timestamp)
   - `ajTenantId`: Keyword (optional, extracted from job args if present)

3. **Retry Policy** (Temporal RetryPolicy):
   - `initial_interval`: Duration (from `retry_on wait:` or config default)
   - `backoff_coefficient`: Float (default 2.0)
   - `maximum_attempts`: Integer (from `retry_on attempts:` or config default)
   - `non_retryable_error_types`: Array of exception class names (from `discard_on`)

4. **Configuration Settings** (Ruby Config Object):
   - `target`: String (Temporal server host:port)
   - `namespace`: String (Temporal namespace)
   - `task_queue_prefix`: String (optional prefix for task queues)
   - `default_activity_timeout`: Duration
   - `default_retry_initial_interval`: Duration
   - `default_retry_backoff`: Float
   - `default_retry_max_attempts`: Integer
   - `logger`: Logger instance
   - `enable_tracing`: Boolean
```

### Context: task-i1-t3 (from 02_Iteration_I1.md)

```markdown
## Task I1.T3: Implement Configuration Module

Create the `ActiveJob::Temporal` configuration module in `lib/activejob/temporal.rb` with a configuration DSL. Implement a `Config` class with attributes: `target` (default: "127.0.0.1:7233"), `namespace` (default: "default"), `task_queue_prefix` (default: nil), `default_activity_timeout` (default: 15.minutes), `default_retry_initial_interval` (default: 30.seconds), `default_retry_backoff` (default: 2.0), `default_retry_max_attempts` (default: 1), `logger` (default: Rails.logger if Rails defined, else Logger.new(STDOUT)), `enable_tracing` (default: true). Provide `ActiveJob::Temporal.configure { |config| ... }` block method and `ActiveJob::Temporal.config` accessor (memoized singleton). Write unit tests in `spec/unit/configuration_spec.rb` covering: default values, configuration block usage, accessor methods, validation (e.g., timeout must be positive). Document configuration options in `docs/configuration_reference.md` with descriptions, types, defaults, and examples.
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** This is the main gem entry point. It contains the `ActiveJob::Temporal` module with the `Configuration` class (lines 57-224). The Configuration class already has comprehensive validation via the `validate!` method (lines 139-146), which calls private validation methods. Note that `max_payload_size_kb` already exists as an attr_accessor (line 83) with a default of 250 (line 102).
    *   **Current State:**
        - Lines 76-84: Attributes defined with `attr_accessor` for simple values
        - Lines 92-104: The `initialize` method sets hardcoded defaults
        - Line 83: `max_payload_size_kb` already exists as an attr_accessor
        - Line 102: Default value `@max_payload_size_kb = 250` is already set
    *   **Recommendation:** You MUST add the `identity` attribute following the same pattern as existing attributes (add to `attr_accessor` list). For environment variable support, you MUST modify the `initialize` method (lines 92-104) to read from ENV with fallbacks to hardcoded defaults. The existing code pattern uses `@variable = value` for simple assignments. Follow this exact style.
    *   **CRITICAL WARNING:** The `max_payload_size_kb` attribute ALREADY EXISTS (line 83, line 102). The task description asks to add it, but it's already there! You should focus ONLY on:
        1. Adding the `identity` attribute
        2. Adding environment variable support for ALL applicable config attributes (including the existing `max_payload_size_kb`)
        3. You MUST NOT duplicate the `max_payload_size_kb` declaration

*   **File:** `docs/configuration_reference.md`
    *   **Summary:** This file documents all configuration options in a table format (lines 7-18). It also includes usage examples and a Search Attributes section.
    *   **Current State:**
        - Lines 7-18: Configuration options table with 9 rows
        - Line 18: `max_payload_size_kb` is already documented
        - Lines 22-35: Usage examples section
        - Lines 45-74: Search Attributes section
    *   **Recommendation:** You MUST add:
        1. A new row in the configuration table for `identity` attribute (insert alphabetically or at the end)
        2. A NEW section called "Environment Variables" between the configuration table and the usage examples (after line 18, before line 20)
        3. This new section must contain a table mapping ENV variable names to configuration attributes
    *   **Tip:** The file already mentions `max_payload_size_kb` on line 18. You do NOT need to modify that row, but you MUST document the ENV variable for it in the new "Environment Variables" section.

*   **File:** `spec/unit/configuration_spec.rb`
    *   **Summary:** This file contains comprehensive unit tests for the Configuration class. It follows RSpec conventions with nested `describe` blocks and uses `subject(:configuration) { described_class.new }` pattern (line 65). Tests are well-organized by concern (defaults, validation, etc.).
    *   **Current State:**
        - Lines 6-8: `before` hook that resets `@config` instance variable for isolation
        - Lines 67-99: Tests for default values
        - Lines 157-407: Comprehensive validation tests from I6.T1
    *   **Recommendation:** You MUST add:
        1. A test in the "defaults" section for the `identity` attribute (should be nil)
        2. A NEW describe block `describe "environment variable support"` after the defaults section
        3. Tests for each ENV variable override (target, namespace, task_queue_prefix, max_payload_size_kb)
        4. Tests verifying that ENV values override hardcoded defaults
        5. Tests verifying that missing ENV variables use hardcoded defaults
    *   **Tip:** For environment variable tests, you MUST use RSpec mocking to stub ENV values BEFORE creating a new Configuration instance. Use this pattern:
        ```ruby
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('TEMPORAL_TARGET').and_return('custom:9999')
        config = described_class.new
        expect(config.target).to eq('custom:9999')
        ```

### Implementation Tips & Notes

*   **CRITICAL:** The task mentions "optionally add environment variable defaults". This wording is misleading—the acceptance criteria EXPLICITLY requires ENV variable support. You MUST implement it, not make it optional.
*   **Note:** The `identity` attribute is described as "worker identity string for observability". This should be a simple String attribute with default `nil`. It's used for identifying which worker process is executing jobs in observability systems. No validation is mentioned in the task, so simple `attr_accessor` is sufficient.
*   **Note:** For environment variable support in the `initialize` method, the standard Ruby pattern is: `@target = ENV['TEMPORAL_TARGET'] || '127.0.0.1:7233'`. However, for the numeric `max_payload_size_kb`, you'll need to handle the conversion properly. The safest approach is:
    ```ruby
    @max_payload_size_kb = (ENV['TEMPORAL_MAX_PAYLOAD_SIZE_KB']&.to_i || 250)
    ```
    This uses safe navigation operator `&.` to avoid calling `to_i` on nil, then uses `|| 250` as fallback.
*   **Warning:** The existing `validate!` method (added in I6.T1) already validates `max_payload_size_kb` in the `validate_payload_size!` method (lines 204-215). You do NOT need to add any validation for the new `identity` attribute (no validation requirements mentioned). The existing validation will continue to work with ENV-sourced values.
*   **Note:** The existing test file has 408+ lines and is well-structured. Your new tests should follow the same style: descriptive test names using `it "does something specific"` format, proper use of `expect` syntax, and organized into logical `describe`/`context` blocks.
*   **Important:** The acceptance criteria states "docs/configuration_reference.md includes table mapping environment variables to config attributes". This means you need to create a NEW table (not modify the existing configuration options table) that shows the mapping between ENV variable names and config attribute names.
*   **Style Note:** The existing code uses `# frozen_string_literal: true` as the first line. All test mocking should use RSpec's built-in stubbing, not modify the actual ENV hash (which could cause test pollution).

### Environment Variable Testing Strategy

You MUST test the following scenarios:

1. **Default behavior (no ENV vars set):** Configuration uses hardcoded defaults
2. **ENV override for target:** Setting `ENV['TEMPORAL_TARGET']` overrides default
3. **ENV override for namespace:** Setting `ENV['TEMPORAL_NAMESPACE']` overrides default
4. **ENV override for task_queue_prefix:** Setting `ENV['TEMPORAL_TASK_QUEUE_PREFIX']` overrides default (from nil to a value)
5. **ENV override for max_payload_size_kb:** Setting `ENV['TEMPORAL_MAX_PAYLOAD_SIZE_KB']` overrides default (must convert string to integer)
6. **Multiple ENV vars:** Setting multiple ENV vars simultaneously works correctly
7. **Empty string ENV values:** Verify behavior when ENV var is set to empty string (should it use default or empty string?)

For testing ENV variables in RSpec, use this pattern:
```ruby
describe "environment variable support" do
  before do
    # Reset the @config instance variable to force new instance creation
    ActiveJob::Temporal.instance_variable_set(:@config, nil)
  end

  it "reads target from TEMPORAL_TARGET environment variable" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TEMPORAL_TARGET').and_return('custom:9999')

    config = described_class.new
    expect(config.target).to eq('custom:9999')
  end

  it "uses default when TEMPORAL_TARGET is not set" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TEMPORAL_TARGET').and_return(nil)

    config = described_class.new
    expect(config.target).to eq('127.0.0.1:7233')
  end

  it "converts TEMPORAL_MAX_PAYLOAD_SIZE_KB to integer" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TEMPORAL_MAX_PAYLOAD_SIZE_KB').and_return('512')

    config = described_class.new
    expect(config.max_payload_size_kb).to eq(512)
  end
end
```

This approach is cleaner than stubbing the ENV constant and allows you to test individual ENV variables without affecting others.

### Documentation Requirements

The acceptance criteria requires TWO distinct documentation additions:

1. **Identity attribute documentation in existing table**: Add a new row to the configuration options table (lines 7-18) for the `identity` attribute:
   ```markdown
   | `identity` | String or `nil` | `nil` | Optional worker identity string for observability and debugging. Useful in multi-worker deployments. |
   ```

2. **New Environment Variables section**: Create a NEW section with a NEW table showing ENV var names → config attribute mappings. This section should be inserted AFTER line 18 (after the configuration table) and BEFORE line 20 (before "Usage Examples"). Example format:
   ```markdown
   ## Environment Variables

   Configuration can also be set via environment variables for 12-factor app compliance. Environment variables take precedence over default values but are overridden by explicit configuration in initializers.

   | Environment Variable | Configuration Attribute | Type | Default if Not Set |
   | --- | --- | --- | --- |
   | `TEMPORAL_TARGET` | `target` | String | `"127.0.0.1:7233"` |
   | `TEMPORAL_NAMESPACE` | `namespace` | String | `"default"` |
   | `TEMPORAL_TASK_QUEUE_PREFIX` | `task_queue_prefix` | String | `nil` |
   | `TEMPORAL_MAX_PAYLOAD_SIZE_KB` | `max_payload_size_kb` | Integer | `250` |

   **Example:** Setting `TEMPORAL_TARGET=temporal.production.com:7233` before your Rails app boots will configure the adapter to connect to that Temporal server, unless you override it in an initializer.
   ```

### Code Changes Required

#### 1. lib/activejob/temporal.rb

**Line 76-84 modification:** Add `identity` to the `attr_accessor` list (alphabetically after `enable_search_attributes` or at the end):
```ruby
attr_accessor :target,
              :namespace,
              :task_queue_prefix,
              :default_retry_backoff,
              :default_retry_max_attempts,
              :logger,
              :enable_tracing,
              :max_payload_size_kb,
              :enable_search_attributes,
              :identity
```

**Lines 92-104 modification:** Update the `initialize` method to read from ENV:
```ruby
def initialize
  @target = ENV['TEMPORAL_TARGET'] || '127.0.0.1:7233'
  @namespace = ENV['TEMPORAL_NAMESPACE'] || 'default'
  @task_queue_prefix = ENV['TEMPORAL_TASK_QUEUE_PREFIX']
  self.default_activity_timeout = 15.minutes
  self.default_retry_initial_interval = 30.seconds
  @default_retry_backoff = 2.0
  @default_retry_max_attempts = 1
  @logger = default_logger
  @enable_tracing = true
  @max_payload_size_kb = (ENV['TEMPORAL_MAX_PAYLOAD_SIZE_KB']&.to_i || 250)
  @enable_search_attributes = true
  @identity = nil
end
```

**YARD documentation:** Add documentation for the new `identity` attribute in the attr_accessor YARD comment block (around lines 58-75). Add this line:
```ruby
# @!attribute [rw] identity
#   @return [String, nil] Optional worker identity for observability (default: nil)
```

#### 2. spec/unit/configuration_spec.rb

**In the "defaults" section (after line 98):** Add test for identity default:
```ruby
it "sets identity to nil by default" do
  expect(configuration.identity).to be_nil
end
```

**After the "defaults" section (after line 99):** Add a new describe block for environment variable support with comprehensive tests for all ENV variables.

#### 3. docs/configuration_reference.md

**After line 18:** Add new row to configuration table for `identity` attribute.

**After line 18 (new section):** Add "Environment Variables" section with table mapping ENV vars to config attributes, including an example.

### Acceptance Criteria Checklist

You MUST ensure all of these criteria are met:

- [ ] Configuration class has `identity` attr_accessor with default nil
- [ ] `identity` is added to the attr_accessor list in lib/activejob/temporal.rb
- [ ] Configuration initialize reads from ENV['TEMPORAL_TARGET'] with fallback to '127.0.0.1:7233'
- [ ] Configuration initialize reads from ENV['TEMPORAL_NAMESPACE'] with fallback to 'default'
- [ ] Configuration initialize reads from ENV['TEMPORAL_TASK_QUEUE_PREFIX'] with fallback to nil
- [ ] Configuration initialize reads from ENV['TEMPORAL_MAX_PAYLOAD_SIZE_KB'] and converts to integer with fallback to 250
- [ ] Setting ENV['TEMPORAL_TARGET']='custom:9999' before config creation sets config.target to 'custom:9999'
- [ ] docs/configuration_reference.md includes `identity` in configuration options table
- [ ] docs/configuration_reference.md includes NEW "Environment Variables" section
- [ ] Environment Variables section includes table mapping 4 ENV vars to config attributes
- [ ] Unit tests verify `identity` default value is nil
- [ ] Unit tests verify ENV variable precedence for target
- [ ] Unit tests verify ENV variable precedence for namespace
- [ ] Unit tests verify ENV variable precedence for task_queue_prefix
- [ ] Unit tests verify ENV variable precedence for max_payload_size_kb (with string-to-integer conversion)
- [ ] Unit tests verify fallback to defaults when ENV vars not set
- [ ] All tests use proper RSpec mocking (allow(ENV).to receive...)
- [ ] `rake spec` passes without errors
- [ ] `rake rubocop` passes without offenses

### Common Pitfalls to Avoid

1. **Do NOT duplicate max_payload_size_kb:** This attribute already exists. Only add ENV variable support for it.
2. **Do NOT modify the existing configuration table for ENV vars:** Create a separate "Environment Variables" section.
3. **Do NOT forget string-to-integer conversion for max_payload_size_kb:** ENV vars are always strings.
4. **Do NOT forget to reset @config in tests:** Each test must create a fresh Configuration instance to test ENV behavior.
5. **Do NOT use actual ENV hash manipulation in tests:** Use RSpec stubs to avoid test pollution.
6. **Do NOT add validation for identity:** No validation requirements mentioned in the task.
7. **Do NOT call validate! automatically:** The existing I6.T1 implementation correctly requires explicit validation calls.

### Integration with I6.T1

This task builds on I6.T1, which added the `validate!` method. Your implementation must:
- Work seamlessly with the existing validation (ENV-sourced values should be validated when `validate!` is called)
- Not break any existing tests from I6.T1
- Follow the same code style and documentation patterns established in I6.T1

The existing validation will automatically validate ENV-sourced values when users call `config.validate!`, so no changes to validation logic are needed for this task.
