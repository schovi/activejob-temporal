# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I6.T1",
  "iteration_id": "I6",
  "iteration_goal": "Enhance Version 2 with robust validation, better error handling, and comprehensive documentation from Version 1 analysis while maintaining Version 2's superior architecture.",
  "description": "Add comprehensive configuration validation to the Configuration class in `lib/activejob/temporal.rb`. Implement a public `validate!` method that calls private validation methods: `validate_target!` (ensure host:port format with regex `/^[\\w.-]+:\\d{1,5}$/`), `validate_namespace!` (ensure alphanumeric/hyphen/underscore only with regex `/^[\\w-]+$/`), `validate_timeouts!` (ensure positive durations for default_activity_timeout and default_retry_initial_interval), `validate_retry_settings!` (ensure default_retry_backoff >= 1.0, default_retry_max_attempts >= 0), `validate_payload_size!` (ensure max_payload_size_kb between 0 and 2097152 bytes / 2MB). Each validation method should raise `ActiveJob::Temporal::ConfigurationError` with descriptive messages on failure. Add the ConfigurationError exception class to the main module. The validate! method should be documented as optional (users can call it explicitly) but NOT automatically called on every config access (to avoid performance overhead). Write comprehensive unit tests in `spec/unit/configuration_spec.rb` covering: valid configurations pass, invalid target format raises error, invalid namespace raises error, negative/zero timeouts raise errors, invalid retry settings raise errors, oversized payload limit raises error.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Version 1 lib/active_job/temporal/configuration.rb:68-148, existing Configuration class in Version 2",
  "target_files": [
    "lib/activejob/temporal.rb",
    "spec/unit/configuration_spec.rb"
  ],
  "input_files": [
    "lib/activejob/temporal.rb",
    "spec/unit/configuration_spec.rb"
  ],
  "deliverables": "Configuration class with validate! method, ConfigurationError exception class, comprehensive validation tests",
  "acceptance_criteria": "ActiveJob::Temporal::ConfigurationError exception class exists; Configuration class has public `validate!` method; Calling `validate!` on valid config does not raise; Calling `validate!` on config with invalid target (e.g., 'badformat') raises ConfigurationError with message matching 'target must match'; Calling `validate!` on config with invalid namespace (e.g., 'has spaces') raises ConfigurationError; Calling `validate!` on config with negative timeout raises ConfigurationError; Calling `validate!` on config with backoff < 1.0 raises ConfigurationError; Calling `validate!` on config with max_payload_size_kb > 2097152 raises ConfigurationError; Unit tests in configuration_spec.rb cover all validation scenarios with descriptive test names; `rake spec` passes; `rake rubocop` passes",
  "dependencies": [],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: nfr-security (from 01_Context_and_Drivers.md)

```markdown
<!-- anchor: nfr-security -->
#### 2.2.6. Security

**Requirement**: Prevent accidental exposure of secrets, resist malicious payloads, and support secure Temporal cluster connections.

**Architectural Impact**:
- Payload size limit (default 250KB, configurable) to prevent memory exhaustion
- No direct Ruby object serialization (Marshal/Oj unsafe modes disabled)
- ActiveJob::Arguments enforces safe serialization (primitives, GlobalID)
- TLS support for Temporal client connection (via `temporalio` gem config)
- Secrets (Temporal API keys, mTLS certs) loaded from environment variables, not committed to code
- Input validation: job class must inherit from `ApplicationJob`, arguments must be serializable

**Targets**:
- Zero known CVEs in `temporalio` gem dependency
- No plaintext secrets in logs or Temporal payloads
- Support Temporal Cloud mTLS authentication (documented in README)
```

### Context: nfr-usability (from 01_Context_and_Drivers.md)

```markdown
<!-- anchor: nfr-usability -->
#### 2.2.7. Usability (Developer Experience)

**Requirement**: Minimal learning curve for Rails developers familiar with ActiveJob.

**Architectural Impact**:
- Zero changes to job class code (standard `ApplicationJob` inheritance)
- Single-line adapter configuration: `config.active_job.queue_adapter = :temporal`
- Sensible defaults for all configuration options (work out-of-box with local Temporal dev server)
- Clear error messages for common mistakes (connection failures, serialization errors, missing worker)
- README with quick start, examples, and migration notes from Sidekiq/Resque

**Targets**:
- Time to first successful job: <15 minutes (including Temporal dev server setup)
- Zero breaking changes between patch versions (semver compliance)
- Issue resolution time: <48 hours for critical bugs
```

### Context: design-preferences (from 01_Context_and_Drivers.md)

```markdown
<!-- anchor: design-preferences -->
#### 2.3.4. Design Preferences

1. **Explicit Over Implicit**:
   - **Preference**: Configuration should be explicit (no "magic" auto-discovery of Temporal connection).
   - **Impact**: Require `ActiveJob::Temporal.configure` block in initializer (no environment-based fallbacks beyond documented ENV vars).

2. **Fail Fast**:
   - **Preference**: Raise errors eagerly (connection failures, serialization errors) rather than silently degrading.
   - **Impact**: `enqueue` raises `ActiveJob::EnqueueError` if Temporal client cannot start workflow (caller must handle).

3. **Minimize Dependencies**:
   - **Preference**: Zero runtime dependencies beyond `temporalio` and Rails.
   - **Impact**: No gems like `dry-rb`, `hanami-utils`; implement retry mapping and serialization inline.

4. **Rails-Native Patterns**:
   - **Preference**: Use Rails conventions (e.g., `Rails.logger`, `Rails.env`, `config/initializers`).
   - **Impact**: Logging uses `Rails.logger` by default; configuration merges with Rails config system.
```

### Context: data-model-overview - Configuration Settings (from 03_System_Structure_and_Data.md)

```markdown
**4. Configuration (Gem Settings)**

Stored in `ActiveJob::Temporal.config` singleton.

| Setting | Type | Default | Purpose |
|---------|------|---------|---------|
| `target` | String | `"127.0.0.1:7233"` | Temporal server address |
| `namespace` | String | `"default"` | Temporal namespace |
| `task_queue_prefix` | String (optional) | `nil` | Prefix for task queue names |
| `default_activity_timeout` | Duration | `15.minutes` | Activity start_to_close_timeout |
| `default_retry_initial_interval` | Duration | `30.seconds` | Retry initial delay |
| `default_retry_backoff` | Float | `2.0` | Exponential backoff factor |
| `default_retry_max_attempts` | Integer | `1` | Max retry attempts if no `retry_on` |
| `logger` | Logger | `Rails.logger` | Logging destination |
| `enable_tracing` | Boolean | `true` | OpenTelemetry tracing toggle |
```

### Context: task-i1-t3 - Original Configuration Implementation (from 02_Iteration_I1.md)

```markdown
<!-- anchor: task-i1-t3 -->
*   **Task 1.3: Implement Configuration Module**
    *   **Task ID:** `I1.T3`
    *   **Description:** Create the `ActiveJob::Temporal` configuration module in `lib/activejob/temporal.rb` with a configuration DSL. Implement a `Config` class with attributes: `target` (default: "127.0.0.1:7233"), `namespace` (default: "default"), `task_queue_prefix` (default: nil), `default_activity_timeout` (default: 15.minutes), `default_retry_initial_interval` (default: 30.seconds), `default_retry_backoff` (default: 2.0), `default_retry_max_attempts` (default: 1), `logger` (default: Rails.logger if Rails defined, else Logger.new(STDOUT)), `enable_tracing` (default: true). Provide `ActiveJob::Temporal.configure { |config| ... }` block method and `ActiveJob::Temporal.config` accessor (memoized singleton). Write unit tests in `spec/unit/configuration_spec.rb` covering: default values, configuration block usage, accessor methods, validation (e.g., timeout must be positive). Document configuration options in `docs/configuration_reference.md` with descriptions, types, defaults, and examples.
    *   **Acceptance Criteria:**
        - `ActiveJob::Temporal.configure { |c| c.target = "localhost:7233" }` sets configuration
        - `ActiveJob::Temporal.config.target` returns configured value
        - Default values are applied when configuration block not called
        - All configuration attributes are readable and writable
        - Unit tests cover all configuration attributes and edge cases (nil values, invalid types)
        - `rake spec` passes for configuration_spec.rb
        - `docs/configuration_reference.md` lists all 9 configuration options with descriptions, types, defaults, and usage examples
        - Documentation is in Markdown format and passes `markdownlint` (if linter configured)
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** This file contains the main module structure with the `Configuration` class already implemented. The Configuration class has all 9 configuration attributes with getters/setters, and it already has basic validation for positive durations in the `default_activity_timeout=` and `default_retry_initial_interval=` setter methods. It uses a private helper method `ensure_positive_duration!` for this validation.
    *   **Current State:**
        - The base exception class `ActiveJob::Temporal::Error < StandardError` already exists at line 42
        - Configuration attributes: `target`, `namespace`, `task_queue_prefix`, `default_retry_backoff`, `default_retry_max_attempts`, `logger`, `enable_tracing`, `max_payload_size_kb`, `enable_search_attributes`
        - Duration attributes with special setters: `default_activity_timeout`, `default_retry_initial_interval`
        - The class follows YARD documentation conventions with extensive inline comments
    *   **Recommendation:** You MUST add the new `ConfigurationError` exception class as a subclass of the existing `ActiveJob::Temporal::Error`. You MUST implement the `validate!` public method in the Configuration class that calls private validation methods. You SHOULD follow the existing pattern of private helper methods (like `ensure_positive_duration!`) for validation logic. You MUST ensure `validate!` is NOT called automatically in the config accessor to avoid performance overhead.

*   **File:** `spec/unit/configuration_spec.rb`
    *   **Summary:** This file contains comprehensive unit tests for the Configuration class with 156 lines of test coverage. It already tests default values, configuration block usage, accessor methods, and basic validation for timeout setters.
    *   **Current Test Coverage:**
        - Tests for `ActiveJob::Temporal.config` memoization
        - Tests for `ActiveJob::Temporal.configure` block
        - Tests for all default values
        - Tests for logger fallback behavior
        - Tests for nil task_queue_prefix handling
        - Tests for positive duration validation in setters (lines 126-155)
    *   **Recommendation:** You MUST add a new describe block for the `validate!` method. You SHOULD organize tests by validation method (validate_target!, validate_namespace!, etc.) with nested contexts for valid/invalid cases. You MUST use descriptive test names following the existing pattern (e.g., "raises when duration is zero or negative"). You SHOULD test each validation rule independently with clear error message expectations.

*   **File:** `.rubocop.yml`
    *   **Summary:** The project uses Rubocop with specific style rules: max line length 120, method length max 20 lines, double-quoted strings enforced, frozen_string_literal required.
    *   **Recommendation:** You MUST ensure all new code follows these rules. Since validation methods may be complex, you SHOULD keep each private validation method focused and under 20 lines. If the `validate!` method becomes too long, you SHOULD extract private helper methods. All files MUST start with `# frozen_string_literal: true`.

*   **File:** `lib/activejob/temporal/logger.rb`
    *   **Summary:** This module provides structured JSON logging with event names. It has methods `log_event`, `info`, `warn`, `error` that accept an event name and attributes hash.
    *   **Recommendation:** You DO NOT need to log validation errors since validation failures raise exceptions that will be caught by the caller. The existing error message pattern in ArgumentError is sufficient for validation failures.

*   **File:** `lib/activejob/temporal/cancel.rb`
    *   **Summary:** This module demonstrates the project's error handling patterns. It uses StandardError rescue blocks, checks specific error types, and uses the Logger module for warnings.
    *   **Recommendation:** You SHOULD follow this pattern for error handling: create specific exception classes, provide descriptive error messages, and handle edge cases gracefully.

*   **File:** `docs/configuration_reference.md`
    *   **Summary:** This file documents all configuration options in a table format with type, default, and description. It includes usage examples and notes about validation.
    *   **Current State:** Line 43 mentions "Duration settings must be positive values" with a note about ArgumentError
    *   **Recommendation:** You DO NOT need to update this file for this task. The documentation already mentions validation behavior. Future tasks may enhance this documentation with information about the new `validate!` method.

### Implementation Tips & Notes

*   **Tip:** The existing `ensure_positive_duration!` method (lines 125-132) provides a good pattern for validation methods. Each validation method should:
    1. Check the specific validation rule
    2. Raise `ActiveJob::Temporal::ConfigurationError` with a descriptive message on failure
    3. Be named with a `!` suffix to indicate it may raise an exception

*   **Tip:** For regex validation patterns, use the Ruby `=~` operator or `String#match?` method. Example:
    ```ruby
    def validate_target!
      return if target =~ /^\w[\w.-]*:\d{1,5}$/
      raise ConfigurationError, "target must match host:port format (e.g., 'localhost:7233'), got: #{target.inspect}"
    end
    ```

*   **Tip:** The payload size validation should convert KB to bytes (multiply by 1024) and check the upper limit of 2097152 KB (2 GB). The lower limit should be 0 or 1 (you should decide based on whether 0 KB makes sense).

*   **Note:** The `validate!` method must be PUBLIC and should call all private validation methods. It should NOT return a value (implicit nil is fine). Example structure:
    ```ruby
    def validate!
      validate_target!
      validate_namespace!
      validate_timeouts!
      validate_retry_settings!
      validate_payload_size!
      nil
    end
    ```

*   **Note:** The task description specifies exact regex patterns:
    - Target: `/^[\w.-]+:\d{1,5}$/` (matches alphanumeric, dots, hyphens, colon, port number 1-5 digits)
    - Namespace: `/^[\w-]+$/` (matches alphanumeric, hyphens, underscores)
    You MUST use these exact patterns or improve them if they have obvious issues (e.g., the target regex should allow at least one character before the colon).

*   **Warning:** The Configuration class already validates timeouts in their setter methods (lines 110-121). Your `validate_timeouts!` method should validate that the CURRENT values are positive, not just rely on the setters. This is important because someone could bypass setters or the internal state could be corrupted.

*   **Warning:** The `validate_retry_settings!` method must check TWO attributes: `default_retry_backoff >= 1.0` AND `default_retry_max_attempts >= 0`. These are separate validations that should both be checked in one method.

*   **Testing Strategy:** You MUST test each validation method comprehensively:
    1. **Valid configurations pass:** Create a config with all valid values and call `validate!` - should not raise
    2. **Invalid target:** Test various invalid formats (no port, invalid characters, negative port)
    3. **Invalid namespace:** Test with spaces, special characters, empty string
    4. **Invalid timeouts:** Test zero and negative values for both timeout attributes
    5. **Invalid retry backoff:** Test backoff < 1.0 (e.g., 0.5, 0, -1)
    6. **Invalid max attempts:** Test negative values
    7. **Invalid payload size:** Test > 2097152 KB and optionally test negative values
    8. **Error messages:** Verify error messages are descriptive and include the invalid value

*   **Code Style:** Follow the existing patterns in the Configuration class:
    - Use YARD documentation comments for all public methods
    - Use `attr_accessor`/`attr_reader` for simple attributes
    - Group related methods together (all validation methods should be private and grouped)
    - Use consistent naming: validation methods end with `!`, predicates with `?`
    - Keep methods focused and under 20 lines (Rubocop limit)

### Exception Design Pattern

Based on the existing code structure:

1. **Add ConfigurationError as a subclass of Error:**
   ```ruby
   class Error < StandardError; end
   class ConfigurationError < Error; end
   ```

2. **Place it in the ActiveJob::Temporal module** (after the Error class definition at line 42)

3. **Use it consistently in all validation methods:**
   ```ruby
   raise ConfigurationError, "descriptive message with context"
   ```

### Test Organization Pattern

Based on existing test structure in `spec/unit/configuration_spec.rb`:

1. **Add a new describe block for #validate! at the end of the Configuration tests:**
   ```ruby
   describe "#validate!" do
     context "with valid configuration" do
       it "does not raise any errors" do
         expect { configuration.validate! }.not_to raise_error
       end
     end

     context "when target is invalid" do
       it "raises ConfigurationError for missing port" do
         configuration.target = "localhost"
         expect { configuration.validate! }.to raise_error(
           ActiveJob::Temporal::ConfigurationError,
           /target must match/
         )
       end
       # More invalid target tests...
     end

     context "when namespace is invalid" do
       # Namespace validation tests...
     end

     # Continue for each validation method...
   end
   ```

2. **Use descriptive context blocks and test names** following the existing pattern

3. **Test both the positive case (no error) and negative cases (specific errors)** for each validation rule

### Key Constraints from Rubocop

- **Max line length: 120 characters** - Break long error messages across lines if needed
- **Max method length: 20 lines** - Keep each validation method focused
- **Frozen string literal: Required** - File already has this
- **Double quotes: Enforced** - Use "strings" not 'strings'

### Performance Consideration

The task explicitly states: "The validate! method should be documented as optional (users can call it explicitly) but NOT automatically called on every config access (to avoid performance overhead)."

This means:
- Do NOT call `validate!` in the Configuration initializer
- Do NOT call `validate!` in attribute setters
- Do NOT call `validate!` in the `config` class method
- Users must explicitly call `ActiveJob::Temporal.config.validate!` if they want validation
- Document this in YARD comments on the `validate!` method

### Acceptance Criteria Checklist

You MUST ensure all of these criteria are met:

- [ ] `ActiveJob::Temporal::ConfigurationError` exception class exists as a subclass of `Error`
- [ ] Configuration class has public `validate!` method with YARD documentation
- [ ] Calling `validate!` on valid config does not raise any errors
- [ ] Invalid target format (e.g., 'badformat', 'host', ':7233') raises ConfigurationError with message matching 'target must match'
- [ ] Invalid namespace (e.g., 'has spaces', 'special!chars') raises ConfigurationError
- [ ] Negative timeout raises ConfigurationError
- [ ] Zero timeout raises ConfigurationError
- [ ] Backoff < 1.0 (e.g., 0.5, 0, -1) raises ConfigurationError
- [ ] max_payload_size_kb > 2097152 raises ConfigurationError
- [ ] Unit tests cover ALL validation scenarios with descriptive test names
- [ ] `rake spec` passes without errors
- [ ] `rake rubocop` passes without offenses
- [ ] All new code has `# frozen_string_literal: true` header
- [ ] All methods have YARD documentation
- [ ] Test names follow existing pattern ("raises when...", "does not raise when...")

### Files to Modify

1. **lib/activejob/temporal.rb:**
   - Add `ConfigurationError` class after line 42
   - Add public `validate!` method to Configuration class
   - Add private validation methods: `validate_target!`, `validate_namespace!`, `validate_timeouts!`, `validate_retry_settings!`, `validate_payload_size!`
   - Add YARD documentation for all new methods

2. **spec/unit/configuration_spec.rb:**
   - Add comprehensive tests for `validate!` method
   - Test each validation rule independently
   - Test valid configurations pass
   - Test invalid configurations raise with correct error messages
   - Ensure all edge cases are covered

### Final Notes

- This task is iteration I6.T1, the first task in Iteration 6, which focuses on "robust validation, better error handling"
- The validation implementation will be used by subsequent tasks (I6.T2 adds more config attributes, I6.T3-I6.T4 enhance other modules)
- Your implementation should be thorough and production-ready, as it forms the foundation for configuration safety
- Clear error messages are critical - users should immediately understand what's wrong and how to fix it
- Follow the "Fail Fast" design preference: validation errors should be explicit and raised immediately when validate! is called
