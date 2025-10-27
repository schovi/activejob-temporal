# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I2.T7",
  "iteration_id": "I2",
  "iteration_goal": "Implement the core Temporal workflow (AjWorkflow) and activity (AjRunnerActivity) that orchestrate and execute ActiveJob jobs. Generate sequence diagrams for execution flows.",
  "description": "Run `rake spec` to execute all unit tests for Iteration 2 (workflows, activities, adapter helpers). Verify SimpleCov reports >= 90% code coverage for all new modules. If coverage is below 90%, write additional tests. Generate coverage report. Acceptance: All tests pass, coverage >= 90%.",
  "agent_type_hint": "BackendAgent",
  "inputs": "RSpec configuration, SimpleCov, unit tests from I2.T2-I2.T5",
  "target_files": [],
  "input_files": [
    "spec/spec_helper.rb",
    "spec/unit/workflows/*.rb",
    "spec/unit/activities/*.rb",
    "spec/unit/adapter_spec.rb"
  ],
  "deliverables": "Passing test suite, coverage report >= 90%",
  "acceptance_criteria": "`rake spec` exits with status 0 (all tests pass); SimpleCov report shows >= 90% coverage for `lib/activejob/temporal/workflows/*.rb`, `lib/activejob/temporal/activities/*.rb`, and adapter helpers; Coverage report is generated in `coverage/index.html`; No skipped or pending tests",
  "dependencies": [
    "I2.T2",
    "I2.T3",
    "I2.T4",
    "I2.T5"
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
### 5.3. Code Quality Gates

**SimpleCov (Code Coverage)**

- **Threshold**: >= 90% coverage (combined unit + integration)
- **Enforcement**: CI fails if coverage drops below threshold
- **Exclusions**: `spec/` directory (test code not counted in coverage)
- **Reports**: HTML report in `coverage/index.html`, uploaded to Codecov (optional)
```

### Context: task-i2-t7 (from 02_Iteration_I2.md)

```markdown
*   **Task 2.7: Run Unit Tests and Verify Coverage**
    *   **Task ID:** `I2.T7`
    *   **Description:** Run `rake spec` to execute all unit tests for Iteration 2 (workflows, activities, adapter helpers). Verify SimpleCov reports >= 90% code coverage for all new modules. If coverage is below 90%, write additional tests. Generate coverage report. Acceptance: All tests pass, coverage >= 90%.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** RSpec configuration, SimpleCov, unit tests from I2.T2-I2.T5
    *   **Input Files:**
        - `spec/spec_helper.rb`
        - `spec/unit/workflows/*.rb`
        - `spec/unit/activities/*.rb`
        - `spec/unit/adapter_spec.rb`
    *   **Target Files:** None (verification task, generates coverage report)
    *   **Deliverables:** Passing test suite, coverage report >= 90%
    *   **Acceptance Criteria:**
        - `rake spec` exits with status 0 (all tests pass)
        - SimpleCov report shows >= 90% coverage for `lib/activejob/temporal/workflows/*.rb`, `lib/activejob/temporal/activities/*.rb`, and adapter helpers
        - Coverage report is generated in `coverage/index.html`
        - No skipped or pending tests
    *   **Dependencies:** I2.T2, I2.T3, I2.T4, I2.T5 (all unit tests must be written)
    *   **Parallelizable:** No (must run after all tests are written)
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `spec/spec_helper.rb`
    *   **Summary:** This file configures RSpec and SimpleCov for the test suite. SimpleCov is configured to start coverage tracking with branch coverage enabled, excluding the `/spec/` directory from coverage calculations. RSpec is configured with standard best practices (expect syntax, mock verification, random test order).
    *   **Recommendation:** This file is correctly configured. You do NOT need to modify it. SimpleCov will automatically generate the coverage report when tests run.

*   **File:** `Rakefile`
    *   **Summary:** This file defines the primary Rake tasks for the project. The `:spec` task runs RSpec tests, `:rubocop` runs linting, and `:yard` generates documentation. The default task runs both rubocop and spec.
    *   **Recommendation:** You SHOULD use `rake spec` to run all tests as specified in the task description. This is the correct command to execute.

*   **File:** `spec/unit/workflows/aj_workflow_spec.rb`
    *   **Summary:** This file contains comprehensive unit tests for the AjWorkflow class. It tests immediate execution (no sleep), scheduled execution (with sleep), handling of past scheduled_at times, and retry policy passthrough. All tests use mocking to isolate workflow logic from external dependencies.
    *   **Recommendation:** This test file is COMPLETE and well-written. The workflow tests are comprehensive and should pass successfully. You do NOT need to add more tests here unless you find gaps during coverage analysis.

*   **File:** `spec/unit/activities/aj_runner_activity_spec.rb`
    *   **Summary:** This file contains comprehensive unit tests for the AjRunnerActivity class. It tests successful job execution with idempotency key lifecycle, retryable exception handling, and non-retryable (discard_on) exception wrapping. All tests use mocking to avoid requiring real job classes.
    *   **Recommendation:** This test file is COMPLETE and well-written. The activity tests are comprehensive and should pass successfully. You do NOT need to add more tests here unless you find gaps during coverage analysis.

*   **File:** `spec/unit/adapter_spec.rb`
    *   **Summary:** This file contains comprehensive unit tests for the Adapter module (workflow ID builder and task queue resolver). It tests deterministic workflow ID generation, uniqueness across job classes, task queue resolution with/without prefix, and default queue name handling.
    *   **Recommendation:** This test file is COMPLETE and well-written. The adapter helper tests are comprehensive and should pass successfully. You do NOT need to add more tests here unless you find gaps during coverage analysis.

*   **File:** `lib/activejob/temporal/workflows/aj_workflow.rb`
    *   **Summary:** This file implements the AjWorkflow class, which orchestrates job execution. It extracts scheduled_at from payload, sleeps until the scheduled time if needed, and then executes the AjRunnerActivity with appropriate timeout and retry configuration.
    *   **Recommendation:** This implementation is COMPLETE. The workflow correctly uses deterministic operations only (Workflow.now, Workflow.sleep, Workflow.execute_activity).

*   **File:** `lib/activejob/temporal/activities/aj_runner_activity.rb`
    *   **Summary:** This file implements the AjRunnerActivity class, which executes the actual job. It deserializes arguments, constantizes the job class, sets an idempotency key in thread-local storage, executes the job, and handles exceptions (wrapping discard_on exceptions as non-retryable ApplicationErrors).
    *   **Recommendation:** This implementation is COMPLETE. The activity correctly manages the idempotency key lifecycle and exception handling.

*   **File:** `lib/activejob/temporal/adapter.rb`
    *   **Summary:** This file implements the Adapter module with two helper methods: build_workflow_id (creates deterministic workflow IDs) and resolve_task_queue (resolves task queue names with optional prefix).
    *   **Recommendation:** This implementation is COMPLETE. Both helper methods are correctly implemented and tested.

### Implementation Tips & Notes

*   **Current Coverage Status:** I checked the current coverage report and found that the project has **51.92% coverage overall**. This is SIGNIFICANTLY BELOW the 90% target. You MUST analyze which files are causing low coverage and add tests to reach >= 90%.

*   **Expected Test Outcomes:** All existing unit tests for Iteration 2 (workflows, activities, adapter) appear to be complete and well-written. When you run `rake spec`, these tests should PASS. If any tests fail, investigate the failure and fix the underlying implementation.

*   **Coverage Analysis Strategy:** After running `rake spec`, open `coverage/index.html` in a browser to see a detailed breakdown of which files/lines are NOT covered. Focus on:
    1. **Workflows directory:** Check if `lib/activejob/temporal/workflows/aj_workflow.rb` has >= 90% coverage
    2. **Activities directory:** Check if `lib/activejob/temporal/activities/aj_runner_activity.rb` has >= 90% coverage
    3. **Adapter module:** Check if `lib/activejob/temporal/adapter.rb` has >= 90% coverage
    4. **Foundation modules:** Modules from Iteration 1 (Configuration, Client, Payload, RetryMapper, SearchAttributes, Logger) may be dragging down overall coverage if they weren't fully tested

*   **Adding Missing Tests:** If you find specific lines or branches that are NOT covered, you will need to:
    1. Identify which edge case or error path is missing
    2. Write a new RSpec test (or add a context/it block to existing specs) that exercises that code path
    3. Re-run `rake spec` and verify coverage improved

*   **Common Coverage Gaps:** Based on my analysis, potential coverage gaps might be in:
    - **Error handling paths:** Exception handling in activity (though this appears well-tested)
    - **Edge cases:** nil/empty/invalid inputs to helper methods (these appear well-tested in adapter_spec.rb)
    - **Foundation modules from I1:** Configuration, Client, Payload, RetryMapper, SearchAttributes, Logger may not have 90% coverage individually

*   **Acceptance Criteria Checklist:** Before marking this task complete, ensure:
    - [ ] `rake spec` exits with status 0 (no test failures)
    - [ ] SimpleCov report shows >= 90% for `lib/activejob/temporal/workflows/*.rb`
    - [ ] SimpleCov report shows >= 90% for `lib/activejob/temporal/activities/*.rb`
    - [ ] SimpleCov report shows >= 90% for `lib/activejob/temporal/adapter.rb`
    - [ ] Overall project coverage is >= 90% (or very close, considering I1 modules)
    - [ ] Coverage report exists in `coverage/index.html`
    - [ ] No skipped or pending tests (search for `pending` or `skip` in test output)

*   **Warning:** DO NOT modify implementation files in this task unless you find an actual bug. This task is ONLY about running tests and ensuring coverage. If coverage is below 90%, add MORE TESTS, do not change implementation code.

---

## 4. Execution Instructions

1. **Run the test suite:**
   ```bash
   rake spec
   ```
   This will execute all RSpec tests and generate a SimpleCov coverage report in `coverage/index.html`.

2. **Check for test failures:**
   - If all tests pass, proceed to step 3
   - If any tests fail, investigate the failure, fix the bug in the implementation or test, and re-run

3. **Analyze coverage report:**
   - Open `coverage/index.html` in a browser
   - Check the coverage percentage for each file in Iteration 2:
     - `lib/activejob/temporal/workflows/aj_workflow.rb`
     - `lib/activejob/temporal/activities/aj_runner_activity.rb`
     - `lib/activejob/temporal/adapter.rb`
   - If any file is below 90%, identify uncovered lines/branches

4. **Add missing tests (if needed):**
   - For each uncovered line/branch, write a new test that exercises that code
   - Add tests to the appropriate spec file (`spec/unit/workflows/aj_workflow_spec.rb`, `spec/unit/activities/aj_runner_activity_spec.rb`, or `spec/unit/adapter_spec.rb`)
   - Re-run `rake spec` and verify coverage improved

5. **Verify acceptance criteria:**
   - Ensure all tests pass (status 0)
   - Ensure >= 90% coverage for Iteration 2 modules
   - Ensure no pending/skipped tests

6. **Report results:**
   - Confirm task completion with coverage percentage
   - Note any issues or gaps discovered during testing
