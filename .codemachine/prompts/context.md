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
  "description": "Run `rake spec:integration` (or `rake spec` with integration tests included) to execute all integration tests written in Iteration 4. Verify all tests pass. Generate coverage report and ensure overall gem coverage (unit + integration) is >= 90%. If coverage is below target, identify gaps and write additional unit or integration tests. Acceptance: All integration tests pass, overall coverage >= 90%.",
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

**Testing strategy: unit tests, integration tests, manual testing, smoke testing.**

This section describes the testing approach for the activejob-temporal gem:

1. **Unit Tests**: Test individual modules in isolation using RSpec with mocking/stubbing to avoid external dependencies. Target >= 90% code coverage. Files tested include Configuration, Client, Payload, RetryMapper, SearchAttributes, Logger, AjWorkflow, AjRunnerActivity, TemporalAdapter.

2. **Integration Tests**: End-to-end tests using a real Temporal test server (temporal-ruby-sdk's test mode or local dev server). Test scenarios include:
   - Immediate job execution
   - Scheduled job execution (set(wait:))
   - Retry behavior (retry_on with transient errors)
   - Discard behavior (discard_on non-retryable errors)
   - Job cancellation with heartbeating
   - Search Attributes visibility

3. **Manual Testing**: Use example Rails app to verify real-world usage

4. **Smoke Testing**: Quick sanity checks after gem build/install

### Context: code-quality-gates (from 03_Verification_and_Glossary.md)

**Quality gates: Rubocop, SimpleCov coverage (>= 90%), YARD docs, dependency scanning, payload size validation.**

Code quality requirements:
- **Rubocop**: Zero offenses with reasonable exceptions documented
- **SimpleCov**: >= 90% line and branch coverage
- **YARD Documentation**: All public APIs documented
- **Dependency Scanning**: No known vulnerabilities
- **Payload Size**: 250KB limit enforced

### Context: integration-strategy (from 03_Verification_and_Glossary.md)

**Component integration order across iterations and external system integration (Temporal, Rails).**

Integration happens progressively:
- Iteration 1-3: Unit-level integration within gem components
- Iteration 4: External integration with Temporal test server
- Integration tests verify entire enqueue → workflow → activity → job execution flow

### Context: release-criteria (from 03_Verification_and_Glossary.md)

**Go/No-Go release criteria for v0.1.0: functional, quality, documentation, security requirements.**

Release criteria include:
1. **Functional**: All user stories implemented and tested
2. **Quality**: >= 90% test coverage, zero Rubocop offenses
3. **Documentation**: Complete README, API docs, migration guide
4. **Security**: No known vulnerabilities, payload size limits enforced
5. **Integration**: All integration tests passing with Temporal test server

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

* **File:** `spec/spec_helper.rb`
  * **Summary:** RSpec configuration with SimpleCov integration for coverage tracking. Enables branch coverage and filters spec files from coverage calculation.
  * **Recommendation:** This configuration is already set up correctly. SimpleCov will automatically generate coverage reports in `coverage/index.html`.

* **File:** `spec/integration/enqueue_spec.rb`
  * **Summary:** Integration tests for immediate job execution and search attributes verification. Tests workflow completion and attribute presence.
  * **Recommendation:** This test is already implemented and includes the search attributes test required by I4.T8.

* **File:** `spec/integration/scheduled_jobs_spec.rb`
  * **Summary:** Integration test for scheduled job execution using `set(wait:)`. Verifies job doesn't execute immediately and uses timer.
  * **Recommendation:** This test is already implemented as required by I4.T4.

* **File:** `spec/integration/retries_spec.rb`
  * **Summary:** Integration tests for retry behavior with `retry_on` and discard behavior with `discard_on`. Verifies workflow history shows correct retry attempts.
  * **Recommendation:** This test covers both I4.T5 and I4.T6 requirements.

* **File:** `spec/integration/cancellation_spec.rb`
  * **Summary:** Integration test for job cancellation via heartbeat mechanism. Verifies workflow is cancelled mid-execution.
  * **Recommendation:** This test is already implemented as required by I4.T7.

* **File:** `coverage/index.html`
  * **Summary:** Most recent SimpleCov coverage report showing 98.17% overall coverage (429 out of 437 relevant lines covered).
  * **Recommendation:** Coverage is already ABOVE the 90% requirement. The task acceptance criteria is already met for coverage.

* **File:** `Rakefile`
  * **Summary:** Defines rake tasks including `spec`, `spec:unit`, `spec:integration`, `rubocop`, and `yard`. Default task runs rubocop and spec.
  * **Recommendation:** Use `rake spec:integration` to run only integration tests, or `rake spec` to run all tests.

### Implementation Tips & Notes

* **Tip:** The coverage report already shows 98.17% coverage, which exceeds the 90% requirement. The task is primarily about VERIFYING this and ensuring all integration tests pass.

* **Note:** There is a Ruby version mismatch issue. The system Ruby is 2.6.10, but the project requires Ruby >= 3.2. The project uses vendored bundle at `vendor/bundle/ruby/3.3.0/`, suggesting the gems were installed with Ruby 3.3.

* **Warning:** When running tests, you MUST use a Ruby 3.2+ interpreter. The bundled gems are compiled for Ruby 3.3, so you should use that version. Common approaches:
  - Use `rvm use 3.3.5` or similar to switch Ruby versions
  - Use `rbenv local 3.3.0` if using rbenv
  - Check if there's a `.ruby-version` file in the project

* **Tip:** The integration tests require a Temporal test server to be running. Check `spec/support/temporal_test_server.rb` for how the test server is started. The docker-compose.yml file in the root may be used to start a local Temporal server.

* **Note:** All integration test files are already complete and implement the requirements from tasks I4.T3 through I4.T8:
  - I4.T3: `enqueue_spec.rb` - immediate execution test (line 26-42)
  - I4.T4: `scheduled_jobs_spec.rb` - scheduled execution test
  - I4.T5: `retries_spec.rb` - retry behavior test (line 30-67)
  - I4.T6: `retries_spec.rb` - discard behavior test (line 69-101)
  - I4.T7: `cancellation_spec.rb` - cancellation test
  - I4.T8: `enqueue_spec.rb` - search attributes test (line 44-88)

* **Warning:** The primary challenge for this task is NOT writing tests (they're done) but RUNNING them successfully with the correct Ruby version and Temporal test environment.

### Execution Strategy

1. **Verify Ruby Version**: Ensure you're using Ruby 3.2+ before running any tests
2. **Start Temporal Test Server**: Either via docker-compose or the test helper will start it automatically
3. **Run Integration Tests**: Execute `rake spec:integration` to run only integration tests, or `rake spec` for all tests
4. **Verify Coverage**: Check `coverage/index.html` after test run to confirm >= 90% coverage
5. **Check Test Results**: All tests should pass with status 0

### Known Issues

* **Ruby Version Mismatch**: System Ruby is 2.6.10 but project needs 3.2+. Solution: Use RVM/rbenv to switch to Ruby 3.3.5
* **Bundle Path**: The project uses a vendored bundle at `vendor/bundle/ruby/3.3.0/` which won't work with system Ruby 2.6

### Current Status Assessment

Based on my analysis:
- ✅ All integration tests are already written (I4.T3-I4.T8 complete)
- ✅ Coverage is already at 98.17% (exceeds 90% requirement)
- ❓ Tests need to be RUN with correct Ruby version to verify they pass
- ❓ Temporal test server needs to be available for integration tests

The task is essentially a **verification task** - confirming that existing tests pass and coverage meets requirements.
