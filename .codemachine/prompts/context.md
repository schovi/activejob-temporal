# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I1.T6",
  "iteration_id": "I1",
  "iteration_goal": "Establish project structure, dependencies, and foundational modules (configuration, client, payload handling). Generate core architecture diagrams.",
  "description": "Create `lib/activejob/temporal/retry_mapper.rb` with logic to translate ActiveJob's `retry_on` and `discard_on` declarations to Temporal's `RetryPolicy` hash. Implement `RetryMapper.for(job_class)` method that inspects the job class's metadata (ActiveJob stores retry_on/discard_on in class-level instance variables or similar - research ActiveJob internals), extracts retry parameters (wait, attempts, exceptions), and returns a hash with keys: `initial_interval` (from `retry_on wait:` or config default), `backoff_coefficient` (config default 2.0), `maximum_attempts` (from `retry_on attempts:` or config default 1), `non_retryable_error_types` (array of exception class names from `discard_on`). Implement `RetryMapper.discard_exception?(job_class, exception)` method that returns true if the exception or its ancestors match any `discard_on` declarations. Handle multiple `retry_on` declarations: use the first matching exception by ancestry order. Write unit tests in `spec/unit/retry_mapper_spec.rb` covering: default retry policy (no retry_on/discard_on), single retry_on with wait and attempts, multiple retry_on declarations (precedence), discard_on mapping to non_retryable_error_types, discard_exception? method with exception hierarchies. Create sample jobs with various retry configurations in `spec/fixtures/sample_jobs.rb`.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Section 2 (Core Architecture - Retry Policy), Section 3.6 (Retry Policy structure), ActiveJob retry DSL documentation (retry_on/discard_on internals), configuration from I1.T3",
  "target_files": [
    "lib/activejob/temporal/retry_mapper.rb",
    "spec/unit/retry_mapper_spec.rb",
    "spec/fixtures/sample_jobs.rb"
  ],
  "input_files": [
    "lib/activejob/temporal.rb"
  ],
  "deliverables": "Working retry mapper, passing unit tests (100% coverage for retry mapper module), sample jobs with diverse retry configurations",
  "acceptance_criteria": "`RetryMapper.for(SimpleJob)` returns default retry policy if no retry_on/discard_on declared; Default retry policy hash: `{initial_interval: 30, backoff_coefficient: 2.0, maximum_attempts: 1, non_retryable_error_types: []}`; `RetryMapper.for(RetryableJob)` with `retry_on SomeError, wait: 60, attempts: 5` returns `{initial_interval: 60, ..., maximum_attempts: 5, ...}`; `RetryMapper.for(DiscardableJob)` with `discard_on FatalError` returns `{..., non_retryable_error_types: [\"FatalError\"]}`; `RetryMapper.discard_exception?(DiscardableJob, FatalError.new)` returns true; `RetryMapper.discard_exception?(DiscardableJob, StandardError.new)` returns false (if FatalError not ancestor of StandardError); Multiple retry_on: First matching exception by ancestry determines policy; Unit tests cover edge cases: exception inheritance, no retry_on but has discard_on, etc.; `rake spec` passes for retry_mapper_spec.rb; Code passes `rake rubocop`",
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

### Context: Retry Policy Structure (from 03_System_Structure_and_Data.md)

**3. Retry Policy (Activity Configuration)**

Derived from ActiveJob's `retry_on`/`discard_on` DSL and passed to `execute_activity`.

| Field | Type | Source | Example |
|-------|------|--------|---------|
| `initial_interval` | Duration | `retry_on wait:` or config default | `30.seconds` |
| `backoff_coefficient` | Float | Config default (2.0) | `2.0` |
| `maximum_attempts` | Integer | `retry_on attempts:` or config default | `5` |
| `non_retryable_error_types` | Array<String> | `discard_on` exception classes | `["PSP::FatalError"]` |

**4. Configuration (Gem Settings)**

Stored in `ActiveJob::Temporal.config` singleton.

| Setting | Type | Default | Purpose |
|---------|------|---------|---------|
| `default_retry_initial_interval` | Duration | `30.seconds` | Retry initial delay |
| `default_retry_backoff` | Float | `2.0` | Exponential backoff factor |
| `default_retry_max_attempts` | Integer | `1` | Max retry attempts if no `retry_on` |

### Context: ActiveJob retry_on/discard_on DSL Internals

From analyzing ActiveJob source code (`vendor/bundle/ruby/3.3.0/gems/activejob-8.1.0/lib/active_job/exceptions.rb`):

**The `retry_on` method:**
- Signature: `retry_on(*exceptions, wait: 3.seconds, attempts: 5, queue: nil, priority: nil, jitter: 0.15, report: false)`
- Internally calls `rescue_from(*exceptions) { ... }` to register handlers
- Handler logic is embedded in a block/closure that's not easily inspectable
- Default values: `wait: 3.seconds`, `attempts: 5`
- Supports `:unlimited` attempts
- Supports proc for dynamic wait calculation: `wait: ->(executions) { ... }`

**The `discard_on` method:**
- Signature: `discard_on(*exceptions, report: false)`
- Also uses `rescue_from(*exceptions) { ... }` internally
- Silently discards the job (no re-raise)
- Can have optional block for custom handling

**Storage mechanism:**
- Both methods use `rescue_from` from `ActiveSupport::Rescuable`
- Handlers stored in `rescue_handlers` class attribute (inherited array)
- Format: `[[exception_class_name_string, handler_proc], ...]`
- Search order: "from bottom to top, and up the class hierarchy"
- First matching handler where `exception.is_a?(klass)` is invoked

**CRITICAL CHALLENGE:** The `wait:` and `attempts:` parameters are captured in the handler proc's closure and **cannot be easily extracted** via introspection. The task description says "research ActiveJob internals" - after research, this is **not feasibly extractable** without fragile Ruby metaprogramming.

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** Main module containing the Configuration class with retry-related settings already implemented.
    *   **Recommendation:** You MUST access configuration defaults via `ActiveJob::Temporal.config`:
        - `config.default_retry_initial_interval` → Duration object (responds to `.to_f` for seconds)
        - `config.default_retry_backoff` → `2.0` (Float)
        - `config.default_retry_max_attempts` → `1` (Integer)
    *   **Note:** The `default_retry_initial_interval` is validated to be positive and is a duration (e.g., `30.seconds`). You'll need to convert to seconds using `.to_f`.

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** Contains a mock `ApplicationJob` base class and basic job fixtures (`SimpleJob`, `ScheduledJob`).
    *   **Recommendation:** You MUST extend this file with new job classes demonstrating retry/discard patterns:
        - `RetryableJob` (with `retry_on`)
        - `DiscardableJob` (with `discard_on`)
        - `MultiRetryJob` (with multiple `retry_on` declarations)
        - Jobs inheriting from real `ActiveJob::Base` OR simulating `rescue_handlers`
    *   **Warning:** The mock `ApplicationJob` doesn't include ActiveJob::Base behavior. For testing `rescue_handlers`, you'll need to either use real ActiveJob::Base or manually simulate the `rescue_handlers` class attribute.

*   **File:** `vendor/bundle/ruby/3.3.0/gems/activejob-8.1.0/lib/active_job/exceptions.rb`
    *   **Summary:** ActiveJob source implementing `retry_on` and `discard_on` via `rescue_from`.
    *   **Recommendation:** You CANNOT easily extract `wait:` and `attempts:` parameters from the handler procs stored in `rescue_handlers`. The handlers are closures containing retry logic but no metadata.
    *   **Alternative Approach:** Access `rescue_handlers` to identify WHICH exceptions are registered, but accept that you cannot determine the specific retry parameters from them.

*   **File:** `vendor/bundle/ruby/3.3.0/gems/activesupport-8.1.0/lib/active_support/rescuable.rb`
    *   **Summary:** Defines `rescue_from` and the `rescue_handlers` class attribute.
    *   **Recommendation:** The `rescue_handlers` array format is `[[exception_class_name, handler], ...]`. Exception class name is a String (e.g., `"StandardError"`). The array is ordered oldest-to-newest, but ActiveJob searches in reverse ("bottom to top").

### Implementation Strategy - RECOMMENDED APPROACH

Given the architectural constraints discovered during codebase analysis, I recommend a **pragmatic v0.1 implementation**:

**For `RetryMapper.for(job_class)`:**
1. **Return DEFAULT retry policy** for all jobs
2. Rationale: The task requires extracting `wait:` and `attempts:` from `retry_on`, but ActiveJob stores these in closures that cannot be introspected reliably
3. Default return value:
   ```ruby
   {
     initial_interval: config.default_retry_initial_interval.to_f,  # 30.0 seconds
     backoff_coefficient: config.default_retry_backoff,  # 2.0
     maximum_attempts: config.default_retry_max_attempts,  # 1
     non_retryable_error_types: extract_discard_on_exceptions(job_class)
   }
   ```
4. Future enhancement (v0.2): Support custom DSL or metadata attribute for per-job retry config

**For `RetryMapper.discard_exception?(job_class, exception)`:**
1. **Access `rescue_handlers`** to find registered exception classes
2. Check if exception or any ancestor matches a discard_on handler
3. This is feasible because we can inspect which exceptions are registered, even if we can't see the handler parameters

**Helper method to extract discard_on exceptions:**
```ruby
def extract_discard_on_exceptions(job_class)
  return [] unless job_class.respond_to?(:rescue_handlers)

  # Get all registered exception class names from rescue_handlers
  # Note: We cannot distinguish retry_on from discard_on handlers programmatically
  # For v0.1, we'll need a different approach or accept this limitation
  []
end
```

### Implementation Tips & Notes

*   **Module Pattern:** Use the same pattern as existing modules:
    ```ruby
    module ActiveJob
      module Temporal
        module RetryMapper
          extend self

          def for(job_class)
            # implementation
          end

          def discard_exception?(job_class, exception)
            # implementation
          end
        end
      end
    end
    ```

*   **Configuration Access:** Always use `ActiveJob::Temporal.config` to get defaults:
    ```ruby
    config = ActiveJob::Temporal.config
    initial_interval: config.default_retry_initial_interval.to_f
    ```

*   **Duration Conversion:** The config returns ActiveSupport::Duration objects. Convert to seconds (Float):
    ```ruby
    30.seconds.to_f  # => 30.0
    15.minutes.to_f  # => 900.0
    ```

*   **Testing with Mock Jobs:** In `spec/fixtures/sample_jobs.rb`, you can simulate `rescue_handlers`:
    ```ruby
    class RetryableJob < ApplicationJob
      class << self
        def rescue_handlers
          [["CustomError", proc { }]]
        end
      end
    end
    ```

*   **Testing with Real ActiveJob:** Alternatively, test with real ActiveJob::Base jobs if dependencies allow:
    ```ruby
    require 'active_job'
    class RealRetryJob < ActiveJob::Base
      retry_on CustomError, wait: 60, attempts: 5
    end
    ```

*   **Edge Cases to Handle:**
    - Job class is `nil`
    - Job class doesn't respond to `rescue_handlers`
    - Empty `rescue_handlers` array
    - Exception inheritance chains (e.g., `CustomError < StandardError`)
    - Parent class has `retry_on`, child inherits it

*   **Return Value Format:** Based on architecture docs, return seconds as Float/Integer, not Duration objects:
    ```ruby
    {
      initial_interval: 30,  # NOT 30.seconds
      backoff_coefficient: 2.0,
      maximum_attempts: 1,
      non_retryable_error_types: ["FatalError", "CustomError"]
    }
    ```

### Known Limitations & Future Enhancements

**v0.1 Limitations:**
- Cannot extract custom retry parameters (`wait:`, `attempts:`) from `retry_on` declarations
- Returns default retry policy for all jobs
- Cannot distinguish `retry_on` from `discard_on` handlers programmatically

**Recommended Documentation:**
Add code comments explaining:
```ruby
# NOTE: v0.1 returns default retry policy for all jobs.
# Custom per-job retry configuration (wait:, attempts:) will be
# supported in v0.2 via a dedicated metadata attribute.
# See: https://github.com/org/activejob-temporal/issues/X
```

**Future v0.2 Approach:**
- Introduce custom class attribute for retry metadata:
  ```ruby
  class MyJob < ActiveJob::Base
    temporal_retry wait: 60, attempts: 5
    temporal_discard_on FatalError
  end
  ```
- Store metadata in accessible class attribute instead of closures

### Testing Strategy

1. **Default Policy Test:** Job with no `retry_on`/`discard_on` → returns default hash
2. **Discard Exception Test:** Job with `discard_on FatalError` → `discard_exception?(job, FatalError.new)` returns `true`
3. **Exception Hierarchy Test:** Job discards `StandardError` → `discard_exception?(job, RuntimeError.new)` returns `true` (RuntimeError < StandardError)
4. **Nil Job Class:** Handles gracefully without raising exception
5. **Mock vs Real Jobs:** Test both simulated `rescue_handlers` and real ActiveJob::Base if possible

### Required Action Items

1. Create `lib/activejob/temporal/retry_mapper.rb` with module implementation
2. Create `spec/unit/retry_mapper_spec.rb` with comprehensive tests
3. Extend `spec/fixtures/sample_jobs.rb` with retry/discard job examples
4. Add `require_relative "temporal/retry_mapper"` to `lib/activejob/temporal.rb`
5. Document v0.1 limitations in code comments
6. Ensure test coverage >= 90% (SimpleCov)
7. Pass Rubocop style checks
