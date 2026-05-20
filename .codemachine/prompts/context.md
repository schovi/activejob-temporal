# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I6.T10",
  "iteration_id": "I6",
  "iteration_goal": "Enhance Version 2 with robust validation, better error handling, and comprehensive documentation from Version 1 analysis while maintaining Version 2's superior architecture.",
  "description": "Run `rvm 4.0.3 do bundle exec rake spec` to execute all tests including new tests written in Iteration 6. Verify that SimpleCov reports >= 90% code coverage for all modules modified or created in this iteration (Configuration validation methods, Cancel enhancements, Payload size validation, new exception classes). If coverage is below 90%, write additional tests to cover edge cases and error paths: (1) Configuration validation: test each validation method independently, test validate! calling all validators, test valid and invalid inputs for each setting; (2) Cancel: test find_workflow with running workflows, closed workflows, non-existent workflows, test connection errors; (3) Payload: test size validation with payloads at 249KB (pass), 250KB (pass), 251KB (fail), test validation skip when max_payload_size_kb is nil; (4) Exception classes: test exception inheritance (ConfigurationError < Error), test raising and catching. Generate coverage report in `coverage/index.html`. Review coverage report to identify uncovered lines and add targeted tests. Acceptance: All tests pass, coverage >= 90% for all modified files.",
  "agent_type_hint": "BackendAgent",
  "inputs": "RSpec configuration, SimpleCov configuration, unit tests from I6.T1-I6.T8",
  "target_files": [
    "spec/unit/configuration_spec.rb",
    "spec/unit/cancel_spec.rb",
    "spec/unit/payload_spec.rb"
  ],
  "input_files": [
    "spec/spec_helper.rb",
    "spec/unit/configuration_spec.rb",
    "spec/unit/cancel_spec.rb",
    "spec/unit/payload_spec.rb",
    "lib/activejob/temporal.rb",
    "lib/activejob/temporal/cancel.rb",
    "lib/activejob/temporal/payload.rb"
  ],
  "deliverables": "Passing test suite with >= 90% coverage for all Iteration 6 changes, coverage report",
  "acceptance_criteria": "`rvm 4.0.3 do bundle exec rake spec` exits with status 0 (all tests pass); SimpleCov report shows >= 90% coverage for: lib/activejob/temporal.rb (Configuration class and exception classes), lib/activejob/temporal/cancel.rb (enhanced cancel logic), lib/activejob/temporal/payload.rb (size validation); Coverage report generated in `coverage/index.html`; No skipped or pending tests (all tests implemented); Test suite includes: 15+ new tests for configuration validation (one per validation method, one for validate!, edge cases), 10+ new tests for cancel enhancements (find_workflow, error handling, return values), 5+ new tests for payload size validation (under limit, at limit, over limit, skip validation, error message format); All edge cases covered: nil values, boundary conditions, exception hierarchies; Test descriptions are clear and follow consistent naming (e.g., 'raises ConfigurationError when target is invalid', 'returns false when workflow already completed'); Running `rvm 4.0.3 do bundle exec rake spec` completes in reasonable time (< 30 seconds for unit tests)",
  "dependencies": ["I6.T1", "I6.T2", "I6.T3", "I6.T4", "I6.T8", "I6.T9"],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: testing-levels (from 03_Verification_and_Glossary.md)

**Testing Strategy Overview**

The activejob-temporal gem employs a multi-level testing strategy to ensure correctness, reliability, and maintainability:

#### Unit Tests
- **Scope**: Test individual modules, classes, and methods in isolation
- **Location**: `spec/unit/`
- **Coverage Target**: >= 90% line coverage for all lib/ files
- **Approach**: Mock external dependencies (Temporal client, Rails, database)
- **Focus Areas**:
  - Configuration module: default values, validation, environment variable support
  - Payload serialization: round-trip serialization, size limits, GlobalID support
  - RetryMapper: retry_on/discard_on translation to Temporal RetryPolicy
  - SearchAttributes: attribute building and type conversion
  - Adapter helpers: workflow ID generation, task queue resolution
  - Logger: structured JSON output, event-based logging

#### SimpleCov Coverage Metrics
- **Tool**: simplecov gem
- **Configuration**: `spec/spec_helper.rb`
- **Target**: >= 90% line coverage for all lib/ files
- **Command**: `rvm 4.0.3 do bundle exec rake spec` (coverage report generated automatically)
- **Report Location**: `coverage/index.html`
- **Exclusions**: None (all production code must be covered)
- **Enforcement**: CI/CD pipeline blocks merge if coverage drops below 90%
- **Metrics Tracked**:
  - Line coverage
  - Branch coverage (if available)
  - File-level coverage breakdown

### Context: code-quality-gates (from 03_Verification_and_Glossary.md)

**Code Quality Gates**

All code changes must pass the following quality gates before merging:

#### RSpec Test Requirements
- All tests must pass (exit status 0)
- No skipped or pending tests
- Test descriptions should be clear and descriptive
- Use RSpec best practices: `describe`, `context`, `it` blocks
- Mock external dependencies (Temporal client, Rails)
- Follow "arrange-act-assert" pattern in tests

#### Coverage Requirements
- Line coverage >= 90% for all production code
- Edge cases must be tested: nil values, boundary conditions, exception paths
- Private methods should be tested indirectly through public APIs
- Exception handling blocks must be covered

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** This file contains the main module definition with the Configuration class (lines 99-329) and exception classes (ConfigurationError on line 62, WorkflowNotFoundError on line 67, TemporalConnectionError on line 73). The Configuration class includes comprehensive validation methods added in I6.T1, I6.T2, and I6.T8.
    *   **Recommendation:** You MUST verify coverage for:
      - All three exception classes (test inheritance, raising, catching)
      - All validation methods: `validate!`, `validate_target!`, `validate_namespace!`, `validate_timeouts!`, `validate_retry_settings!`, `validate_payload_size!`, `validate_worker_concurrency!`
      - Environment variable reading logic (lines 144-157)
      - The `ensure_positive_duration!` helper method (lines 227-234)
    *   **Key Methods to Verify:**
      - Lines 213-221: `validate!` method that calls all validators
      - Lines 238-244: `validate_target!` with regex matching
      - Lines 248-254: `validate_namespace!` with alphanumeric validation
      - Lines 258-275: `validate_timeouts!` and `validate_positive_duration_value!`
      - Lines 279-289: `validate_retry_settings!` with backoff and attempts checks
      - Lines 293-304: `validate_payload_size!` with 2GB limit check
      - Lines 308-318: `validate_worker_concurrency!` with positive value checks

*   **File:** `spec/unit/configuration_spec.rb`
    *   **Summary:** This file contains 610 lines of comprehensive tests for the Configuration class. The tests cover ALL validation scenarios required by the task.
    *   **Recommendation:** This test file is ALREADY COMPLETE and comprehensive. It includes:
      - 50+ validation tests covering all edge cases (lines 308-607)
      - Environment variable tests (lines 113-250)
      - Default value tests (lines 67-111)
      - Setter tests for timeouts (lines 277-306)
    *   **Coverage Assessment:** Based on code review, this spec should provide near-complete coverage for Configuration class validation. If coverage is below 90%, check for:
      - Exception class tests (may be missing inheritance tests)
      - Private helper methods not being exercised
      - Edge cases in environment variable handling

*   **File:** `lib/activejob/temporal/cancel.rb`
    *   **Summary:** This file implements the Cancel module with enhanced workflow discovery added in I6.T3. It includes query-based workflow detection for running and closed workflows.
    *   **Recommendation:** Verify coverage for:
      - Lines 64-81: The main `cancel` method with query logic
      - Lines 89-97: The `find_workflow` method
      - Lines 106-113: The `running_workflows_query` method
      - Lines 119-126: The `closed_workflows_query` method
      - Lines 132-139: Connection error handling (rescue block)
    *   **Critical Paths to Test:**
      - Workflow found in running workflows → cancel succeeds
      - Workflow found in closed workflows → returns false, logs warning
      - Workflow not found → raises WorkflowNotFoundError
      - Connection error → raises TemporalConnectionError
      - Logger calls for all scenarios

*   **File:** `spec/unit/cancel_spec.rb`
    *   **Summary:** This file contains 155 lines of tests for the Cancel module with comprehensive mocking of Temporal client.
    *   **Recommendation:** This test file appears complete based on requirements. It covers:
      - Running workflow cancellation (lines 55-82)
      - Completed workflow detection (lines 84-117)
      - Workflow not found error (lines 119-136)
      - Connection failures (lines 138-153)
    *   **Coverage Assessment:** Should provide excellent coverage for cancel logic. If coverage is low, check for:
      - Query building methods not being hit
      - Logger method calls not being tested
      - Edge cases in workflow info parsing

*   **File:** `lib/activejob/temporal/payload.rb`
    *   **Summary:** This file includes payload size validation added in I6.T4. The `validate_size!` method is defined on lines 93-102 and called from `from_job` on line 73.
    *   **Recommendation:** Verify coverage for:
      - Lines 93-102: The `validate_size!` method
      - Line 73: The call to `validate_size!` in `from_job`
      - Lines 97-102: The error message formatting
      - Edge case: When max_payload_size_kb is nil or zero
    *   **Key Implementation Note:** The error message must include actual size and max size in KB format.

*   **File:** `spec/unit/payload_spec.rb`
    *   **Summary:** This file contains 167 lines of tests for the Payload module with size validation tests on lines 79-136.
    *   **Recommendation:** The existing tests are comprehensive. They cover:
      - Payload under limit (lines 79-87)
      - Payload at exact limit (lines 89-101)
      - Payload over limit (lines 103-113)
      - Error message format (lines 115-128)
      - Non-serializable objects (lines 130-135)
    *   **Coverage Assessment:** Should provide good coverage. If coverage is low, check if the "payload at limit" test is actually executing `validate_size!` with a payload near 250KB.
    *   **Missing Tests:** The task mentions "test validation skip when max_payload_size_kb is nil" but I don't see this implemented in payload.rb. This may not be required.

*   **File:** `spec/spec_helper.rb`
    *   **Summary:** This file likely contains SimpleCov configuration and RSpec setup.
    *   **Recommendation:** Read this file to understand:
      - SimpleCov configuration (minimum coverage threshold)
      - Which files are included/excluded from coverage
      - Coverage report format and location
      - Any custom RSpec matchers or helpers

### Implementation Tips & Notes

*   **Critical: Bundler Error:** The earlier attempt to run `rvm 4.0.3 do bundle exec rake spec` failed with a bundler error: "uninitialized constant Gem::Resolver::APISet::GemParser". This is a Ruby/Bundler version mismatch. You MUST resolve this before running tests. Possible solutions:
    1. Try running RSpec directly: `rvm 4.0.3 do bundle exec rspec spec/unit/` (bypasses rake)
    2. Check Ruby version through the repository toolchain: `rvm 4.0.3 do ruby -v`
    3. Try `rvm 4.0.3 do bundle exec rspec spec/unit/` to use bundled versions

*   **Tip:** Based on my code review, the existing test files are extremely comprehensive. The task asks for "15+ new tests for configuration validation" but configuration_spec.rb already has 50+ validation tests. These tests were likely written in I6.T1. You should verify this by checking if those tests already exist before adding duplicates.

*   **Note:** The acceptance criteria mentions "test validation skip when max_payload_size_kb is nil" but I don't see this logic implemented in payload.rb. The `validate_size!` method doesn't check if max_payload_size_kb is nil before validating. This may be a documentation error or a missing feature. You should clarify this before adding tests.

*   **Tip:** To test exception class inheritance, add these simple tests if they're missing:
    ```ruby
    describe "Exception classes" do
      it "ConfigurationError inherits from Error" do
        expect(ActiveJob::Temporal::ConfigurationError).to be < ActiveJob::Temporal::Error
      end

      it "WorkflowNotFoundError inherits from Error" do
        expect(ActiveJob::Temporal::WorkflowNotFoundError).to be < ActiveJob::Temporal::Error
      end

      it "TemporalConnectionError inherits from Error" do
        expect(ActiveJob::Temporal::TemporalConnectionError).to be < ActiveJob::Temporal::Error
      end

      it "Error inherits from StandardError" do
        expect(ActiveJob::Temporal::Error).to be < StandardError
      end
    end
    ```

*   **Warning:** The task has a dependency on I6.T9 (Rubocop compliance). If I6.T9 wasn't completed, there may be style issues that cause test failures or warnings. Verify that I6.T9 is marked as done.

*   **Note:** The coverage target is >= 90% for THREE specific files:
    1. `lib/activejob/temporal.rb` (Configuration class and exception classes)
    2. `lib/activejob/temporal/cancel.rb` (enhanced cancel logic)
    3. `lib/activejob/temporal/payload.rb` (size validation)

*   **Tip:** If coverage is already >= 90%, you should NOT add more tests. The task says "If coverage is below 90%, write additional tests". Only add tests if needed to reach the threshold.

### Testing Strategy for This Task

1. **First Priority: Fix the Bundler/Ruby Environment**
   - Resolve the bundler error to enable test execution
   - Try alternative methods to run tests if rake fails

2. **Second Priority: Run Tests and Get Coverage Report**
   - Execute the test suite: `rvm 4.0.3 do bundle exec rake spec` or `rvm 4.0.3 do bundle exec rspec spec/unit/`
   - Capture coverage metrics from SimpleCov output
   - Identify which files have coverage below 90%

3. **Third Priority: Analyze Coverage Gaps**
   - Review the coverage report in `coverage/index.html`
   - Identify specific uncovered lines in the three target files
   - Determine if gaps are in main code paths or edge cases

4. **Fourth Priority: Add Targeted Tests (ONLY if needed)**
   - Add tests ONLY for uncovered lines
   - Focus on edge cases and error paths
   - Do NOT duplicate existing tests

5. **Final Verification**
   - Ensure all tests pass (exit status 0)
   - Verify coverage is >= 90% for all three target files
   - Check that coverage report is generated in `coverage/index.html`

### Likely Coverage Gaps to Check

Based on my code review, if coverage is below 90%, it's most likely due to:

1. **Exception class tests:** May be missing tests for exception inheritance
2. **Private helper methods:** `ensure_positive_duration!` and `validate_positive_duration_value!` may not be fully covered
3. **Edge cases in Cancel module:** Query building methods may not be hit by all tests
4. **Logger calls:** Logger.info, Logger.warn, Logger.error calls may not be covered (but these might be excluded from coverage)
5. **Environment variable edge cases:** May be missing tests for malformed env var values

### Files to Review for Coverage

**Priority 1** (most likely to need additional tests):
- `lib/activejob/temporal.rb` - Check exception class coverage and private methods

**Priority 2** (check carefully):
- `lib/activejob/temporal/cancel.rb` - Check query method coverage and error paths

**Priority 3** (likely complete):
- `lib/activejob/temporal/payload.rb` - Size validation tests appear comprehensive

---

## 4. Execution Checklist

Before you start, ensure you:

1. ✅ Understand that existing test files are comprehensive (932 total lines of tests)
2. ✅ Resolve the bundler/Ruby environment issue to enable test execution
3. ✅ Run the test suite and capture coverage metrics
4. ✅ Review the coverage report to identify specific gaps
5. ✅ Add tests ONLY for uncovered lines (do not duplicate existing tests)
6. ✅ Verify all tests pass with no skipped or pending tests
7. ✅ Confirm coverage is >= 90% for all three target files
8. ✅ Ensure coverage report is generated in `coverage/index.html`

---

## 5. Success Criteria Summary

Your implementation will be considered successful when:

- `rvm 4.0.3 do bundle exec rake spec` exits with status 0 (all tests pass)
- SimpleCov reports >= 90% coverage for:
  - `lib/activejob/temporal.rb` (Configuration class and exception classes)
  - `lib/activejob/temporal/cancel.rb` (enhanced cancel logic)
  - `lib/activejob/temporal/payload.rb` (size validation)
- Coverage report is generated in `coverage/index.html`
- No skipped or pending tests exist
- Test descriptions are clear and follow existing naming conventions
- All edge cases are covered: nil values, boundary conditions, exception hierarchies
- Test suite completes in reasonable time (< 30 seconds for unit tests)

**Important:** The task asks for "15+ new tests for configuration validation, 10+ new tests for cancel, 5+ new tests for payload" but my code review shows these tests already exist in the spec files. Verify the test count and coverage percentage - you may only need to add a few edge case tests, not write 30+ new tests from scratch.

Good luck with your implementation!
