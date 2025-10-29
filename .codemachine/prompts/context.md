# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I4.T10",
  "iteration_id": "I4",
  "iteration_goal": "Implement the Temporal worker bootstrap script, write comprehensive integration tests with a real Temporal test server, and validate end-to-end functionality (enqueue → workflow → activity → job execution).",
  "description": "Run `rake rubocop` on entire codebase (lib/, spec/, bin/). Fix any Rubocop offenses introduced in Iteration 4 (worker script, integration tests). Update `.rubocop.yml` if needed. Acceptance: `rake rubocop` passes with zero offenses across entire project.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Rubocop configuration, all code from I1-I4",
  "target_files": [
    "lib/**/*.rb",
    "spec/**/*.rb",
    "bin/temporal-worker",
    ".rubocop.yml"
  ],
  "input_files": [
    "lib/**/*.rb",
    "spec/**/*.rb",
    "bin/temporal-worker",
    ".rubocop.yml"
  ],
  "deliverables": "Clean codebase passing Rubocop checks",
  "acceptance_criteria": "`rake rubocop` exits with status 0 (zero offenses); All auto-correctable offenses are fixed; Any manual fixes are applied; Worker script (`bin/temporal-worker`) passes Rubocop checks; Integration test files pass Rubocop checks",
  "dependencies": [
    "I4.T1",
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

### Context: code-quality-gates (from 03_Verification_and_Glossary.md)

**Quality gates: Rubocop, SimpleCov coverage (>= 90%), YARD docs, dependency scanning, payload size validation.**

Code quality requirements:
- **Rubocop**: Zero offenses with reasonable exceptions documented
- **SimpleCov**: >= 90% line and branch coverage
- **YARD Documentation**: All public APIs documented
- **Dependency Scanning**: No known vulnerabilities
- **Payload Size**: 250KB limit enforced

The project enforces strict code quality standards. Rubocop must run cleanly with zero offenses. Any exceptions to Rubocop rules should be documented in `.rubocop.yml` with clear justification.

### Context: iteration-4-plan (from 02_Iteration_I4.md)

**Iteration 4 plan: Worker bootstrap script, integration tests with Temporal test server.**

This iteration focused on:
1. Creating the worker bootstrap script (`bin/temporal-worker`)
2. Setting up Temporal test server helpers
3. Writing comprehensive integration tests for all execution flows
4. Ensuring all tests pass and coverage meets >= 90%
5. Running Rubocop to ensure code quality

The final task (I4.T10) is to ensure all code written in Iteration 4 passes Rubocop checks.

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

* **File:** `.rubocop.yml`
  * **Summary:** RuboCop configuration file defining style rules and exceptions for the project.
  * **Recommendation:** Check this file first to understand project-specific style rules and any existing exceptions.

* **File:** `Rakefile`
  * **Summary:** Defines rake tasks including `rubocop`, `spec`, and default task. The rubocop task is configured to check all Ruby files.
  * **Recommendation:** Use `rake rubocop` to run the style checks as specified in the task.

* **File:** `bin/temporal-worker`
  * **Summary:** Worker bootstrap script created in I4.T1. This is an executable Ruby script that should also pass Rubocop checks.
  * **Recommendation:** Ensure this script adheres to Rubocop style rules, particularly for executable scripts.

* **File:** `spec/integration/*.rb`
  * **Summary:** Integration test files created in I4.T3-I4.T8. These should also pass Rubocop checks.
  * **Recommendation:** Check integration test files for any style violations.

### Implementation Tips & Notes

* **Tip:** The project already has extensive test coverage (99.32%) and all tests pass. Task I4.T9 is COMPLETE - all integration tests pass successfully.

* **Note:** This task (I4.T10) is specifically focused on code STYLE checking with Rubocop, not functionality. The code works; it just needs to meet style standards.

* **Warning:** The system Ruby version is 2.6.10, but the project requires Ruby 3.2+. You MUST use Ruby 3.3.5 via RVM for all commands.

* **Tip:** Rubocop can auto-correct many style violations. Run `rake rubocop:autocorrect` or `rubocop -a` to automatically fix issues before manual review.

* **Note:** Common Rubocop offenses in integration tests and worker scripts include:
  - Line length violations (usually fixable)
  - Metrics violations (method complexity, file length)
  - Style/Documentation violations (missing class/module comments)

* **Strategy:** Follow this sequence:
  1. Run `rake rubocop` to see current violations
  2. Run `rubocop -a` to auto-correct simple issues
  3. Manually fix remaining violations or add justified exceptions to `.rubocop.yml`
  4. Re-run `rake rubocop` to verify zero offenses

### Execution Strategy

1. **Switch to Ruby 3.3.5**: Use `rvm use 3.3.5` before running any commands
2. **Run Rubocop**: Execute `rake rubocop` to identify violations
3. **Auto-correct**: Run `rubocop -a` to fix auto-correctable issues
4. **Manual Fixes**: Address remaining violations manually
5. **Document Exceptions**: If any rules need exceptions, document them in `.rubocop.yml`
6. **Verify**: Re-run `rake rubocop` to confirm zero offenses

### Known Issues

* **Ruby Version**: System Ruby is 2.6.10; MUST use RVM to switch to Ruby 3.3.5
* **PATH Warning**: RVM shows a PATH warning but this doesn't affect functionality

### Current Status Assessment

Based on previous task completion:
- ✅ All integration tests written and passing (I4.T3-I4.T8)
- ✅ Coverage at 99.32%, exceeds 90% requirement (I4.T9 COMPLETE)
- ❓ Rubocop status unknown - need to run to identify violations (I4.T10 IN PROGRESS)

The task is straightforward: ensure all code passes Rubocop style checks. This is primarily a style verification/cleanup task rather than new feature development.

### Previous Rubocop Status

The project has been maintaining Rubocop compliance throughout development (I1.T9, I2.T6, I3.T7 all included Rubocop checks). Iteration 4 added:
- Worker bootstrap script (`bin/temporal-worker`)
- Integration tests (`spec/integration/*.rb`)

These new files need to be checked for Rubocop compliance. Since previous iterations passed Rubocop, most lib/ code should already be compliant.
