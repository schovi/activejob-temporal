# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I1.T10",
  "iteration_id": "I1",
  "iteration_goal": "Establish project structure, dependencies, and foundational modules (configuration, client, payload handling). Generate core architecture diagrams.",
  "description": "Run `rake spec` to execute all unit tests written in Iteration 1. Verify that SimpleCov reports >= 90% code coverage for all modules created in this iteration (Configuration, Client, Payload, RetryMapper, SearchAttributes, Logger). If coverage is below 90%, write additional tests to cover edge cases and error paths. Generate coverage report in `coverage/index.html`. Acceptance: All tests pass, coverage >= 90%.",
  "agent_type_hint": "BackendAgent",
  "inputs": "RSpec configuration, SimpleCov configuration, unit tests from I1.T3-I1.T8",
  "target_files": [],
  "input_files": [
    "spec/spec_helper.rb",
    "spec/unit/*.rb"
  ],
  "deliverables": "Passing test suite, coverage report >= 90%",
  "acceptance_criteria": "`rake spec` exits with status 0 (all tests pass); SimpleCov report shows >= 90% coverage for `lib/activejob/temporal/*.rb` files; Coverage report is generated in `coverage/index.html`; No skipped or pending tests (all tests must be implemented)",
  "dependencies": [
    "I1.T3",
    "I1.T4",
    "I1.T5",
    "I1.T6",
    "I1.T7",
    "I1.T8"
  ],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: testing-levels (from 03_Verification_and_Glossary.md)

```markdown
<!-- anchor: testing-levels -->
### 5.1. Testing Levels

The activejob-temporal gem employs a comprehensive, multi-layered testing strategy to ensure correctness, reliability, and production readiness.

**Unit Testing (RSpec)**

- **Scope**: Individual classes and modules in isolation
- **Location**: `spec/unit/`
- **Coverage Target**: >= 90% code coverage for each module
- **Mocking Strategy**: Mock external dependencies (Temporal client, workflow/activity execution, job classes) to isolate logic
- **Key Areas**:
  - Configuration module: default values, configuration block, validation
  - Payload serializer: round-trip serialization, GlobalID support, size limits, error handling
  - Retry mapper: retry_on/discard_on translation, exception hierarchy handling
  - Search attributes builder: metadata extraction, tenant handling
  - Temporal client: memoization, connection error handling
  - Adapter: enqueue/enqueue_at logic, workflow ID generation, task queue resolution
  - Workflow: sleep logic (mocked), activity invocation (mocked)
  - Activity: job instantiation, error mapping, idempotency key lifecycle
  - Cancellation API: workflow handle retrieval, cancel call, error handling
- **Tools**: RSpec 3.x, SimpleCov for coverage
```

### Context: code-quality-gates (from 03_Verification_and_Glossary.md)

```markdown
<!-- anchor: code-quality-gates -->
### 5.3. Code Quality Gates

Every iteration and release must pass these quality gates:

**SimpleCov (Code Coverage)**

- **Trigger**: On every `rake spec` run
- **Target**: >= 90% line coverage, >= 80% branch coverage
- **Report**: `coverage/index.html` (HTML report with per-file breakdown)
- **Pass Criteria**: Coverage threshold met for all `lib/` files
- **Command**: Integrated into RSpec (configured in `spec_helper.rb`)
- **Exclusions**: `spec/` directory, vendored dependencies
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Current Coverage Status

Based on the latest coverage report analysis:
- **Overall Line Coverage**: 96.75% (238/246 lines) ✅
- **Overall Branch Coverage**: 76.4% (68/89 branches)
- **8 lines missed**, **21 branches missed**

**Per-File Coverage Breakdown:**

| File | Line Coverage | Branch Coverage |
|------|---------------|-----------------|
| `lib/activejob/temporal.rb` | 100.00% | 100.00% |
| `lib/activejob/temporal/client.rb` | 100.00% | 83.33% |
| `lib/activejob/temporal/logger.rb` | 89.47% | 55.56% |
| `lib/activejob/temporal/payload.rb` | 100.00% | 100.00% |
| `lib/activejob/temporal/retry_mapper.rb` | 95.24% | 70.00% |
| `lib/activejob/temporal/search_attributes.rb` | 100.00% | 83.33% |

### Relevant Existing Code

*   **File:** `spec/spec_helper.rb`
    *   **Summary:** RSpec configuration with SimpleCov integration, enabling both line and branch coverage tracking.
    *   **Implementation:** SimpleCov is already configured and working correctly. The configuration filters out `/spec/` directory and enables branch coverage.
    *   **Recommendation:** Do NOT modify this file. The SimpleCov setup is correct.

*   **File:** `Rakefile`
    *   **Summary:** Rake task definitions for running specs, rubocop, and yard documentation.
    *   **Implementation:** Contains `RSpec::Core::RakeTask.new(:spec)` which is the standard way to run tests.
    *   **Recommendation:** Use `rake spec` or the test script `./tools/test.sh` to run tests.

*   **File:** `spec/unit/*.rb` (6 files)
    *   **Summary:** Unit test files for Configuration, Client, Payload, RetryMapper, SearchAttributes, and Logger modules.
    *   **Current Status:** All test files exist and are passing.
    *   **Recommendation:** These tests need to be enhanced to achieve >= 90% branch coverage.

### Implementation Tips & Notes

**Coverage Gaps Identified:**

1.  **`lib/activejob/temporal/logger.rb` (89.47% line, 55.56% branch)**
    *   **Missing Coverage:** The logger has the lowest line coverage at 89.47%.
    *   **Branch Coverage Issue:** Only 55.56% branch coverage indicates missing test cases for conditional logic.
    *   **Likely Gaps:**
        - The `semantic_logger_available?` method likely has an uncovered branch (when SemanticLogger is defined)
        - The `validate_event!` method may have uncovered edge cases (non-String/Symbol event names)
        - The `normalize_attributes` method likely has uncovered branches (nil vs Hash vs other types)
    *   **Action Required:** Write additional tests in `spec/unit/logger_spec.rb` to cover:
        - Invalid event name types (Integer, Array, etc.)
        - nil attributes handling
        - Logger that doesn't respond to a log level
        - SemanticLogger path (if feasible to mock)

2.  **`lib/activejob/temporal/retry_mapper.rb` (95.24% line, 70.00% branch)**
    *   **Missing Coverage:** Needs 5% more line coverage to reach 100%.
    *   **Branch Coverage Issue:** 70% branch coverage indicates several conditional branches are untested.
    *   **Likely Gaps:**
        - The `constantize_handler_class` method has exception handling that may not be tested
        - The `:unlimited` attempts case in `attempts_from` may not be covered
        - Edge cases in `handles_exception?` for Module vs instance comparisons
        - The `interval_from` method's fallback for Proc/Symbol wait values
    *   **Action Required:** Write additional tests in `spec/unit/retry_mapper_spec.rb` to cover:
        - Jobs with `:unlimited` attempts
        - Non-numeric/non-Duration wait values (Proc, Symbol)
        - Invalid attempts values that trigger rescue clause
        - NameError handling in `constantize_handler_class`
        - Edge cases where exception is nil or job_class is nil

3.  **`lib/activejob/temporal/client.rb` (100% line, 83.33% branch)**
    *   **Branch Coverage Issue:** Although line coverage is 100%, branch coverage at 83.33% indicates uncovered conditional paths.
    *   **Likely Gaps:** TLS configuration branches or connection error branches.
    *   **Action Required:** Review `spec/unit/client_spec.rb` to ensure all conditional branches are tested.

4.  **`lib/activejob/temporal/search_attributes.rb` (100% line, 83.33% branch)**
    *   **Branch Coverage Issue:** One or more conditional branches are not covered.
    *   **Likely Gaps:** Tenant ID extraction logic may have uncovered branches.
    *   **Action Required:** Review `spec/unit/search_attributes_spec.rb` to cover all tenant_id extraction scenarios.

**Test Execution Note:**

*   **Warning:** There is a Ruby version mismatch issue in the environment. The system default Ruby is 2.6.10, but the project requires Ruby >= 3.2.
*   **Solution:** Use the project's bundled gems by running tests via the provided script: `./tools/test.sh` or directly with the vendored RSpec binary.
*   **Alternative:** If `bundle exec rake spec` fails due to bundler issues, check for RVM or rbenv Ruby version management.

**Coverage Calculation:**

To achieve the target >= 90% coverage across ALL modules:
- **Current Overall:** 96.75% line coverage ✅ (Already exceeds 90%)
- **Branch Coverage:** 76.4% (Below ideal 80%, but task focuses on line coverage)
- **Action:** The task primarily requires >= 90% **line coverage**, which is already achieved at 96.75%.
- **Improvement Goal:** Increase branch coverage from 76.4% to >= 80% by adding tests for the identified gaps.

**Specific Test Additions Needed:**

1.  **`spec/unit/logger_spec.rb`:**
    ```ruby
    # Add test for invalid event name type
    it "raises when event_name is not a String or Symbol" do
      expect { logger_helper.log_event(123, {}) }.to raise_error(ArgumentError, /event_name/)
    end

    # Add test for nil attributes
    it "handles nil attributes gracefully" do
      logger_helper.log_event("test_event", nil)
      payload = parsed_lines.first
      expect(payload["event"]).to eq("test_event")
    end

    # Add test for logger without log level support
    it "returns early if logger doesn't respond to log level" do
      allow(ruby_logger).to receive(:respond_to?).with(:info).and_return(false)
      expect { logger_helper.info("test_event") }.not_to raise_error
    end
    ```

2.  **`spec/unit/retry_mapper_spec.rb`:**
    ```ruby
    # Add test for unlimited attempts
    it "handles :unlimited attempts" do
      # Define job with retry_on SomeError, attempts: :unlimited
      # Verify policy has maximum_attempts: 0
    end

    # Add test for non-numeric wait value
    it "falls back to default for Proc wait values" do
      # Define job with retry_on SomeError, wait: ->(executions) { executions * 30 }
      # Verify policy uses default_retry_initial_interval
    end

    # Add test for invalid attempts value
    it "falls back to default for invalid attempts" do
      # Define job with retry_on SomeError, attempts: "not_a_number"
      # Verify policy uses default_retry_max_attempts
    end
    ```

3.  **`spec/unit/client_spec.rb`:**
    - Review existing tests and ensure all conditional branches are covered
    - Add tests for any TLS-related configuration branches

4.  **`spec/unit/search_attributes_spec.rb`:**
    - Review existing tests and ensure all tenant_id extraction branches are covered
    - Add tests for jobs without tenant_id, jobs with nil tenant, etc.

### Quality Gates to Pass

1.  **All Tests Pass:** `rake spec` must exit with status 0
2.  **Line Coverage >= 90%:** Already achieved at 96.75%
3.  **Target Branch Coverage >= 80%:** Currently at 76.4%, needs improvement
4.  **No Skipped Tests:** All tests must be implemented (no pending examples)
5.  **Coverage Report Generated:** `coverage/index.html` must exist and be up-to-date

### Recommended Execution Steps

1.  **Run Current Tests:**
    ```bash
    ./tools/test.sh
    ```
    Or if that fails due to bundler issues:
    ```bash
    cd /Users/schovi/work/activejob-temporal
    rspec spec/unit
    ```

2.  **Review Coverage Report:**
    - Open `coverage/index.html` in a browser
    - Identify exactly which lines and branches are uncovered
    - Click on each file with < 90% coverage to see highlighted uncovered code

3.  **Write Missing Tests:**
    - Focus first on `logger_spec.rb` (89.47% → 100%)
    - Then `retry_mapper_spec.rb` (95.24% → 100%)
    - Then improve branch coverage in `client_spec.rb` and `search_attributes_spec.rb`

4.  **Verify Coverage:**
    - Run tests again after adding new test cases
    - Confirm >= 90% line coverage for ALL modules
    - Confirm >= 80% branch coverage (stretch goal)

5.  **Generate Final Report:**
    - Ensure `coverage/index.html` is regenerated with latest results
    - Take note of final coverage percentages for acceptance verification

### Success Criteria Summary

✅ **Already Achieved:**
- Overall line coverage of 96.75% exceeds the 90% target
- All 6 core modules have tests in place
- SimpleCov is configured and working correctly
- All tests are currently passing (based on the existence of the coverage report)

⚠️ **Needs Improvement:**
- `logger.rb`: Increase from 89.47% to >= 90% (at least 1 more line)
- `retry_mapper.rb`: Increase from 95.24% to >= 100% (at least 2 more lines)
- Branch coverage: Increase from 76.4% to >= 80% (at least 4 more branches)

🎯 **Final Goal:**
- Every module in `lib/activejob/temporal/*.rb` at >= 90% line coverage
- Overall coverage >= 90% (already achieved)
- All tests passing
- Coverage report generated and saved

---

**IMPORTANT FINAL NOTE:**

The task asks you to verify >= 90% coverage and write additional tests **if coverage is below 90%**. The current overall coverage of **96.75%** already exceeds this threshold. However, individual modules `logger.rb` (89.47%) and potentially others need improvement.

Your task is to:
1. Confirm tests pass by running `rake spec` or `./tools/test.sh`
2. Identify which specific modules are below 90%
3. Write targeted tests to bring those modules to >= 90%
4. Verify the final coverage report shows >= 90% for all modules
5. Ensure the coverage report is properly generated in `coverage/index.html`

Focus on quality over quantity - write meaningful tests that cover real edge cases and error paths, not just dummy tests to inflate numbers.

---

**END OF BRIEFING PACKAGE**
