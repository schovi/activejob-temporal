# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I4.T9",
  "iteration_id": "I4",
  "iteration_goal": "Implement the Temporal worker bootstrap script, write comprehensive integration tests with a real Temporal test server, and validate end-to-end functionality (enqueue → workflow → activity → job execution).",
  "description": "Run `rake spec:integration` (or `rake spec`) to execute all integration tests written in Iteration 4. Verify all tests pass. Generate coverage report and ensure overall gem coverage (unit + integration) is >= 90%. If coverage is below target, identify gaps and write additional unit or integration tests. Acceptance: All integration tests pass, overall coverage >= 90%.",
  "agent_type_hint": "BackendAgent",
  "inputs": "RSpec configuration, SimpleCov, all integration tests from I4.T3-I4.T8",
  "target_files": [],
  "input_files": [
    "spec/spec_helper.rb",
    "spec/integration/*.rb"
  ],
  "deliverables": "Passing integration test suite, overall coverage report >= 90%",
  "acceptance_criteria": "`rake spec:integration` (or `rake spec`) exits with status 0 (all integration tests pass); SimpleCov report shows >= 90% overall code coverage (lib/ directory); Coverage report includes both unit and integration test coverage; All integration tests run successfully with Temporal test server; No flaky tests (tests pass consistently on multiple runs)",
  "dependencies": [
    "I4.T3",
    "I4.T4",
    "I4.T5",
    "I4.T6",
    "I4.T7",
    "I4.T8"
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

**Integration Testing (RSpec with Temporal Test Server)**

- **Scope**: End-to-end workflows with real Temporal server
- **Location**: `spec/integration/`
- **Environment**: Temporal test server (in-memory or Docker-based)
- **Coverage Target**: >= 90% overall coverage (combined with unit tests)
- **Key Scenarios**:
  - **Immediate Job Execution**: Enqueue → Workflow → Activity → Job performs → Completion
```

### Context: code-quality-gates (from 03_Verification_and_Glossary.md)

```markdown
### 5.3. Code Quality Gates

**Rubocop (Linting & Style)**

- **Configuration**: `.rubocop.yml` with project-specific rules
- **Enforcement**: CI fails on any offenses (zero-tolerance policy)
- **Auto-Correction**: Run `rubocop -A` to auto-fix safe offenses
- **Custom Rules**:
  - Max line length: 120 characters (configurable)
  - Max method complexity: 10 (cyclomatic complexity)
  - Enforce Ruby 3.2+ syntax features
- **Exclusions**: `spec/fixtures/` (sample jobs may intentionally violate style for testing)

**SimpleCov (Code Coverage)**

- **Threshold**: >= 90% coverage (combined unit + integration)
- **Enforcement**: CI fails if coverage drops below threshold
- **Exclusions**: `spec/` directory (test code not counted in coverage)
- **Reports**: HTML report in `coverage/index.html`, uploaded to Codecov (optional)

**YARD (API Documentation)**

- **Requirement**: All public classes and methods must have YARD comments
- **Enforcement**: `rake yard` must run without warnings
- **Tags Required**: `@param`, `@return`, `@raise` (if applicable), `@example` (for key methods)
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### 🚨 **CRITICAL FINDING: Coverage is BELOW Target at 73.73%**

I reviewed the coverage report at `coverage/index.html` (generated 2025-10-29T10:25:35) and found:
- **Current coverage: 73.73%** (320 lines covered out of 434 relevant lines)
- **114 lines are currently uncovered**
- **Target: >= 90% (390.6 lines minimum)**
- **Gap: 71 additional lines must be covered**

This is significantly below the required 90% threshold specified in the acceptance criteria.

**What this means for your task:**
You MUST identify which modules have insufficient coverage and write additional tests to bring overall coverage above 90%. This is the PRIMARY objective of this task.

### Relevant Existing Code

#### File: `spec/spec_helper.rb`
**Summary:** Main RSpec configuration file that sets up SimpleCov for code coverage tracking with branch coverage enabled. Excludes `/spec/` directory from coverage calculation.

**Recommendation:** This file is already correctly configured. You do NOT need to modify it. SimpleCov will automatically run when you execute `rake spec` and generate an HTML report in `coverage/index.html`.

**Key Configuration:**
- Branch coverage enabled: `enable_coverage :branch`
- Spec files excluded: `add_filter "/spec/"`
- Automatically requires `activejob/temporal` and test helpers

#### File: `Rakefile`
**Summary:** Defines rake tasks for running tests with separate tasks for unit tests (`rake spec:unit`) and integration tests (`rake spec:integration`), plus a combined `rake spec` task.

**Recommendation:** You SHOULD use `rake spec` to run ALL tests (unit + integration) to get complete coverage metrics. The default task also runs rubocop before tests.

**Available Commands:**
- `rake spec` - Runs all tests (unit + integration)
- `rake spec:unit` - Runs only unit tests in `spec/unit/`
- `rake spec:integration` - Runs only integration tests in `spec/integration/`
- `rake default` - Runs rubocop and then spec

#### File: `.rubocop.yml`
**Summary:** Rubocop configuration with project-specific rules (120 char line length, spec/ blocks excluded from BlockLength metrics, global vars allowed in specs).

**Recommendation:** The configuration is already set correctly. All code MUST pass rubocop checks. The file excludes `spec/**/*` from certain metrics which is appropriate for test code.

#### File: `spec/support/temporal_test_server.rb`
**Summary:** Integration test helper that manages Temporal test server connection. Sets up test namespace "test" and verifies connection before running integration tests.

**Recommendation:** This helper is robust and handles server connection automatically. Integration tests MUST have a running Temporal test server at `127.0.0.1:7233` (or custom via `TEMPORAL_TEST_TARGET` env var). The helper will raise `ServerNotAvailableError` if the server is not reachable.

**Key Implementation Details:**
- Test namespace: `"test"`
- Default target: `"127.0.0.1:7233"`
- Automatically configures ActiveJob::Temporal for tests
- RSpec hooks ensure setup before suite, teardown after suite

#### File: `spec/fixtures/sample_jobs.rb`
**Summary:** Defines test job classes used in integration tests: `TestJob`, `RetryTestJob`, `DiscardTestJob`, `LongRunningJob`, and various unit test fixtures.

**Recommendation:** These fixtures are complete and follow ActiveJob conventions. You SHOULD reuse these existing job classes in tests rather than creating new ones. All job classes properly inherit from `ActiveJob::Base` and use appropriate retry/discard configurations.

#### File: `spec/integration/enqueue_spec.rb`
**Summary:** Integration test for immediate job execution and search attributes verification. Uses Temporal worker in background thread, waits for job completion, and verifies workflow status.

**Recommendation:** This test demonstrates the correct pattern for integration tests:
1. Start worker in thread with unique task queue
2. Enqueue job with `perform_later`
3. Wait for result using timeout loop
4. Verify workflow completion and attributes

**Key Pattern to Follow:**
```ruby
task_queue = "test-#{SecureRandom.hex(4)}"  # Unique queue per test
@worker_thread = start_worker(task_queue)
job = TestJob.set(queue: task_queue).perform_later(42)
wait_for_result(42)
# Verify results...
ensure
  stop_worker(@worker_thread)
end
```

#### File: `spec/integration/retries_spec.rb`
**Summary:** Integration tests for retry and discard behaviors. Verifies retry counts, workflow history events, and that discard_on prevents retries.

**Recommendation:** This test shows how to inspect Temporal workflow history to verify retry behavior:
- Checks `activity_task_started_event_attributes.attempt` to verify retry count
- Uses global variables (`$attempt_count`, `$test_result`) to track execution state across retries
- Queries workflow history with `handle.fetch_history`

### Implementation Tips & Notes

**Tip 1: How to Identify Coverage Gaps**

Run `bundle exec rake spec` and then open `coverage/index.html` in a browser. SimpleCov provides a detailed breakdown showing:
- Which files have low coverage (highlighted in different colors)
- Which specific lines are uncovered (highlighted in red)
- Which branches are untested (if/else paths)

You SHOULD inspect this report to identify which modules need additional test coverage. The report will show each file with its percentage and highlight uncovered lines in red.

**Tip 2: Current Integration Tests (All Complete)**

The following integration tests exist and are complete:
- `spec/integration/temporal_connection_spec.rb` - smoke test for Temporal connection
- `spec/integration/enqueue_spec.rb` - immediate job execution + search attributes
- `spec/integration/scheduled_jobs_spec.rb` - scheduled job execution with `set(wait:)`
- `spec/integration/retries_spec.rb` - retry and discard behaviors
- `spec/integration/cancellation_spec.rb` - job cancellation

All five integration test files (I4.T3-I4.T8) have been completed. You SHOULD verify they all pass, but the main issue is likely insufficient unit test coverage.

**Tip 3: Running Tests Efficiently**

```bash
# Run ALL tests (unit + integration) - THIS IS WHAT YOU NEED
bundle exec rake spec

# Run only integration tests
bundle exec rake spec:integration

# Run only unit tests
bundle exec rake spec:unit

# Run single file
bundle exec rspec spec/integration/enqueue_spec.rb

# Run with coverage report
COVERAGE=true bundle exec rake spec
```

**Tip 4: Temporal Test Server Requirement**

Integration tests REQUIRE a running Temporal test server. If you see `ServerNotAvailableError`, you need to start Temporal first:

```bash
# Option 1: Local dev server (recommended)
temporal server start-dev --namespace test

# Option 2: Docker
docker run --rm -p 7233:7233 -p 8233:8233 temporalio/auto-setup:latest
```

The test server must be running BEFORE you execute integration tests. Unit tests do not require it.

**Tip 5: Coverage Target Calculation**

SimpleCov calculates coverage as: `(covered_lines / relevant_lines) * 100`

**Current state:**
- 320 / 434 = 73.73%

**To reach 90%:**
- Need at least 391 lines covered (434 * 0.90 = 390.6)

**Gap:**
- 71 additional lines must be covered (391 - 320 = 71)

**Strategy:**
Focus on writing unit tests for uncovered code paths, especially error handling and edge cases.

**Note: What "coverage" means in this project**

- Only `lib/` directory is counted (spec/ is excluded by SimpleCov filter)
- Branch coverage is enabled (if/else branches are tracked separately)
- Target is 90% overall, not per-file (some files can be < 90% if others are higher)
- Both unit and integration tests contribute to coverage
- Coverage is calculated across all files in `lib/activejob/temporal/`

**Warning: Flaky Tests**

Integration tests that interact with Temporal worker threads can be flaky if:
- Worker startup timing is inconsistent (tests already include `sleep 0.5` to mitigate)
- Timeouts are too short (current tests use 5-10 second timeouts which should be sufficient)
- Temporal server is under load or slow to respond

You SHOULD run the test suite multiple times (at least 3 times) to ensure no flakiness. The acceptance criteria specifically requires "tests pass consistently on multiple runs."

**Note: Most Likely Coverage Gaps**

Based on the 73.73% coverage (below 90% target), the most likely areas with insufficient coverage are:

1. **Error handling paths** - Exception handling branches in adapter, activity, workflow
2. **Configuration edge cases** - Invalid configuration values, nil handling, type coercion
3. **Cancellation edge cases** - Workflow not found, already completed workflows, connection errors
4. **Payload edge cases** - Size limits enforcement, serialization errors, GlobalID failures, unsupported types
5. **Retry mapper edge cases** - Multiple retry_on declarations, exception inheritance hierarchies, invalid attempts values

You SHOULD check the coverage report HTML to identify which specific modules are below 90% coverage and which lines are uncovered (highlighted in red).

### Step-by-Step Execution Plan

**Phase 1: Verify Test Infrastructure**

1. **Check if Temporal test server is running**
   ```bash
   # Try connecting to Temporal
   bundle exec rspec spec/integration/temporal_connection_spec.rb
   ```
   - If it fails with `ServerNotAvailableError`, start Temporal server:
     ```bash
     temporal server start-dev --namespace test
     ```
   - Leave server running in a separate terminal for the duration of testing

**Phase 2: Run Complete Test Suite**

2. **Execute all tests to get baseline coverage**
   ```bash
   bundle exec rake spec
   ```
   - This will run both unit and integration tests
   - SimpleCov will automatically generate coverage report
   - Note the exit code (should be 0 if all tests pass)

**Phase 3: Analyze Coverage Results**

3. **Open the coverage report**
   ```bash
   open coverage/index.html
   # Or manually browse to coverage/index.html
   ```

4. **Identify coverage gaps**
   - Look at the "All Files" summary page
   - Find files with < 90% coverage (highlighted in red/yellow)
   - Click into individual files to see uncovered lines (highlighted in red)
   - Note which specific code paths are untested:
     - Error handling blocks (rescue clauses)
     - Edge cases (nil checks, empty arrays)
     - Alternative branches (elsif, else)
     - Rarely-used configuration paths

**Phase 4: Write Additional Tests**

5. **Create targeted unit tests for uncovered code**
   - Focus on the files with lowest coverage first
   - Add tests to existing `spec/unit/*_spec.rb` files
   - Prioritize error handling and edge cases
   - Example areas to test:
     - `lib/activejob/temporal/adapter.rb` - error handling for Temporal connection failures
     - `lib/activejob/temporal/payload.rb` - size limit enforcement, serialization errors
     - `lib/activejob/temporal/retry_mapper.rb` - invalid attempts values, complex exception hierarchies
     - `lib/activejob/temporal/cancel.rb` - workflow not found, connection errors

**Phase 5: Verify Improvement**

6. **Re-run test suite and check coverage**
   ```bash
   bundle exec rake spec
   ```
   - Verify all tests still pass (exit code 0)
   - Check new coverage percentage in `coverage/index.html`
   - Repeat steps 3-6 until coverage >= 90%

**Phase 6: Stability Testing**

7. **Run test suite multiple times to check for flakiness**
   ```bash
   # Run 3 times in a row
   bundle exec rake spec && bundle exec rake spec && bundle exec rake spec
   ```
   - All runs should pass consistently
   - If any run fails, investigate and fix flaky tests
   - Common causes: timing issues, shared state, race conditions

**Phase 7: Final Verification**

8. **Confirm all acceptance criteria met**
   - ✅ `rake spec` exits with status 0 (all tests pass)
   - ✅ SimpleCov report shows >= 90% overall coverage
   - ✅ Coverage report includes both unit and integration tests
   - ✅ Integration tests run successfully with Temporal server
   - ✅ No flaky tests (consistent results across multiple runs)

### Expected Modules Requiring Additional Coverage

Based on common patterns in testing, these modules are most likely to need additional unit test coverage:

1. **`lib/activejob/temporal/adapter.rb`**
   - Error handling when Temporal server is unreachable
   - Payload size limit enforcement
   - Configuration edge cases

2. **`lib/activejob/temporal/payload.rb`**
   - Serialization errors for unsupported types
   - Size limit enforcement (>250KB)
   - GlobalID serialization edge cases

3. **`lib/activejob/temporal/retry_mapper.rb`**
   - Invalid `attempts` values (non-integer, negative)
   - Complex exception inheritance hierarchies
   - Multiple `retry_on` declarations with overlapping exceptions

4. **`lib/activejob/temporal/cancel.rb`**
   - Workflow not found errors
   - Connection failures to Temporal
   - Already completed workflow cancellation

5. **`lib/activejob/temporal/workflows/aj_workflow.rb`**
   - Error handling in workflow execution
   - Edge cases in sleep duration calculation

6. **`lib/activejob/temporal/activities/aj_runner_activity.rb`**
   - Error mapping edge cases
   - Idempotency key lifecycle errors
   - Job class constantization failures

### Quick Reference Commands

```bash
# Start Temporal test server (required for integration tests)
temporal server start-dev --namespace test

# Run all tests with coverage
bundle exec rake spec

# Run only unit tests (faster, no Temporal server needed)
bundle exec rake spec:unit

# Run only integration tests (requires Temporal server)
bundle exec rake spec:integration

# View coverage report
open coverage/index.html

# Run tests multiple times to check stability
for i in {1..3}; do bundle exec rake spec || break; done
```

### Success Criteria Checklist

Before marking this task complete, verify:

- [ ] Temporal test server is running
- [ ] `bundle exec rake spec` exits with status 0
- [ ] All integration tests pass (5 test files)
- [ ] All unit tests pass
- [ ] Coverage report shows >= 90% overall coverage
- [ ] Coverage report is in `coverage/index.html`
- [ ] No skipped or pending tests
- [ ] Test suite passes consistently (3 runs in a row)
- [ ] No flaky tests observed
