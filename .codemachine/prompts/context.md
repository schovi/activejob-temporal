# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I2.T6",
  "iteration_id": "I2",
  "iteration_goal": "Implement the core Temporal workflow (AjWorkflow) and activity (AjRunnerActivity) that orchestrate and execute ActiveJob jobs. Generate sequence diagrams for execution flows.",
  "description": "Run `rake rubocop` on all code written in Iteration 2 (workflows, activities, adapter helpers). Fix any Rubocop offenses. Ensure code adheres to Ruby style guide. Update `.rubocop.yml` if needed with justified exceptions. Acceptance: `rake rubocop` passes with zero offenses.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Rubocop configuration, code from I2.T2-I2.T5",
  "target_files": [
    "lib/activejob/temporal/workflows/aj_workflow.rb",
    "lib/activejob/temporal/activities/aj_runner_activity.rb",
    "lib/activejob/temporal/adapter.rb",
    "spec/unit/workflows/*.rb",
    "spec/unit/activities/*.rb",
    "spec/unit/adapter_spec.rb",
    ".rubocop.yml"
  ],
  "input_files": [
    "lib/activejob/temporal/workflows/aj_workflow.rb",
    "lib/activejob/temporal/activities/aj_runner_activity.rb",
    "lib/activejob/temporal/adapter.rb",
    "spec/unit/workflows/*.rb",
    "spec/unit/activities/*.rb",
    "spec/unit/adapter_spec.rb",
    ".rubocop.yml"
  ],
  "deliverables": "Clean code passing Rubocop checks",
  "acceptance_criteria": "`rake rubocop` exits with status 0 (zero offenses); All auto-correctable offenses are fixed; Any manual fixes are applied; If `.rubocop.yml` is updated, changes are documented",
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
```

### Context: task-i2-t6 (from 02_Iteration_I2.md)

```markdown
*   **Task 2.6: Run Rubocop and Fix Style Issues**
    *   **Task ID:** `I2.T6`
    *   **Description:** Run `rake rubocop` on all code written in Iteration 2 (workflows, activities, adapter helpers). Fix any Rubocop offenses. Ensure code adheres to Ruby style guide. Update `.rubocop.yml` if needed with justified exceptions. Acceptance: `rake rubocop` passes with zero offenses.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Rubocop configuration, code from I2.T2-I2.T5
    *   **Input Files:**
        - `lib/activejob/temporal/workflows/aj_workflow.rb`
        - `lib/activejob/temporal/activities/aj_runner_activity.rb`
        - `lib/activejob/temporal/adapter.rb`
        - `spec/unit/workflows/*.rb`
        - `spec/unit/activities/*.rb`
        - `spec/unit/adapter_spec.rb`
        - `.rubocop.yml`
    *   **Target Files:** All Ruby files in `lib/activejob/temporal/workflows/`, `lib/activejob/temporal/activities/`, `lib/activejob/temporal/adapter.rb`, and corresponding specs (updated with style fixes)
    *   **Deliverables:** Clean code passing Rubocop checks
    *   **Acceptance Criteria:**
        - `rake rubocop` exits with status 0 (zero offenses)
        - All auto-correctable offenses are fixed
        - Any manual fixes are applied
        - If `.rubocop.yml` is updated, changes are documented
    *   **Dependencies:** I2.T2, I2.T3, I2.T4, I2.T5 (all code must be written)
    *   **Parallelizable:** No (must run after all code is written)
```

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

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `.rubocop.yml`
    *   **Summary:** The project's Rubocop configuration file with project-specific rules. Key settings include Ruby 3.2 target, 120 char line length, spec exclusions for block length, and double quotes as the string literal style.
    *   **Recommendation:** You SHOULD review this file to understand the current rules. The configuration is well-structured with exclusions for `vendor/`, `tmp/`, and `pkg/` directories.
    *   **Current Configuration:**
        - Target Ruby Version: 3.2
        - Line Length: Max 120 characters
        - Block Length: Max 25 (excluded for specs)
        - Method Length: Max 20
        - Module Length: Max 200
        - Documentation: Disabled
        - String Literals: Enforced double quotes
        - Filename check: Disabled for `lib/activejob-temporal.rb`
        - Development Dependencies check: Disabled

*   **File:** `Rakefile`
    *   **Summary:** Defines rake tasks including `rubocop`, `spec`, and `yard`. The default task runs both rubocop and spec.
    *   **Recommendation:** You MUST use `rake rubocop` or `bundle exec rubocop` to run the linter. The rake task is already configured via RuboCop::RakeTask.

*   **File:** `lib/activejob/temporal/workflows/aj_workflow.rb`
    *   **Summary:** Implements the Temporal workflow orchestration logic with scheduled execution support (sleep, activity invocation).
    *   **Current Status:** The code is well-structured with clear separation of concerns (extract_scheduled_time, sleep_until, activity_options private methods).
    *   **Potential Issues:** The code looks clean and follows Ruby best practices. The use of stub classes for Temporalio when not loaded is appropriate for testing.
    *   **Code Quality:** 59 lines total, includes frozen_string_literal, proper module nesting, private methods for internal logic.

*   **File:** `lib/activejob/temporal/activities/aj_runner_activity.rb`
    *   **Summary:** Implements the Temporal activity that executes ActiveJob jobs with idempotency key management and exception handling.
    *   **Current Status:** Code includes comprehensive Temporalio stubs for testing, proper error handling, and idempotency key lifecycle management.
    *   **Potential Issues:** The file has substantial stub code (lines 8-54) to support testing without real Temporal SDK. This is acceptable and documented with comments.
    *   **Code Quality:** 107 lines total, well-organized with clear separation between stub definitions and actual implementation.

*   **File:** `lib/activejob/temporal/adapter.rb`
    *   **Summary:** Provides helper methods for workflow ID generation and task queue resolution.
    *   **Current Status:** Simple module with two well-documented methods using YARD format. Code is clean and follows functional programming style with `module_function`.
    *   **Potential Issues:** No obvious style issues. The code is concise and clear (30 lines total).

*   **File:** `spec/unit/workflows/aj_workflow_spec.rb`
    *   **Summary:** Comprehensive RSpec tests for AjWorkflow covering immediate execution, scheduled execution, past scheduled times, and retry policy handling.
    *   **Current Status:** Well-structured tests with proper mocking, clear context blocks, and descriptive test names.
    *   **Code Quality:** 106 lines, uses RSpec best practices with let blocks, before blocks, and clear expectations.

*   **File:** `spec/unit/activities/aj_runner_activity_spec.rb`
    *   **Summary:** RSpec tests for AjRunnerActivity covering job execution, idempotency key lifecycle, retryable exceptions, and discard_on behavior.
    *   **Current Status:** Thorough test coverage with proper use of doubles and stubs.
    *   **Code Quality:** 76 lines, well-organized with clear test cases and proper mocking.

*   **File:** `spec/unit/adapter_spec.rb`
    *   **Summary:** RSpec tests for adapter helper methods (workflow ID building and task queue resolution).
    *   **Current Status:** Comprehensive test coverage with multiple contexts and edge cases.
    *   **Code Quality:** 134 lines, excellent use of RSpec contexts to organize test scenarios.

### Implementation Tips & Notes

*   **Tip:** The project enforces zero-tolerance for Rubocop offenses. Run `rake rubocop` or `bundle exec rubocop` first to see all violations.
*   **Tip:** Use `rubocop -A` or `bundle exec rubocop -A` to automatically fix all safe violations. This will handle most style issues automatically.
*   **Tip:** If you encounter offenses that cannot be auto-fixed, you should:
    1. First try to fix them manually following Ruby style guide best practices
    2. Only add exclusions to `.rubocop.yml` if there's a strong justification
    3. Document any exclusions with clear comments explaining why
*   **Note:** The existing `.rubocop.yml` already has reasonable exclusions:
    - `spec/**/*` is excluded from BlockLength check (common for RSpec tests)
    - `Style/Documentation` is disabled (project doesn't require class-level docs for everything)
    - Development dependencies check is disabled for the gemspec
*   **Note:** All files in scope already use `# frozen_string_literal: true` magic comment, which is good.
*   **Note:** The project uses double quotes for string literals (enforced by `.rubocop.yml`), so ensure all string literals use `"` not `'`.
*   **Warning:** Do NOT add blanket disables or too many exclusions to `.rubocop.yml`. The plan emphasizes maintaining high code quality standards. Only update `.rubocop.yml` if absolutely necessary with proper justification.
*   **Process:** Follow this workflow:
    1. Run `bundle exec rubocop` to see all current violations
    2. Run `bundle exec rubocop -A` to auto-correct safe offenses
    3. Review remaining offenses and fix manually
    4. Run `bundle exec rubocop` again to verify zero offenses
    5. If any offenses cannot be reasonably fixed, document the justification and consider whether to update `.rubocop.yml`

### Expected Outcome

Based on my review, the code quality is already high. I expect:
- Most or all offenses will be auto-correctable
- You may need to make minor manual adjustments (whitespace, line breaks)
- You SHOULD NOT need to update `.rubocop.yml` unless unexpected issues arise
- All files should pass with zero offenses after running auto-correct

### Files in Scope for This Task

Target files that MUST be checked and fixed:
1. `lib/activejob/temporal/workflows/aj_workflow.rb` (59 lines)
2. `lib/activejob/temporal/activities/aj_runner_activity.rb` (107 lines)
3. `lib/activejob/temporal/adapter.rb` (30 lines)
4. `spec/unit/workflows/aj_workflow_spec.rb` (106 lines)
5. `spec/unit/activities/aj_runner_activity_spec.rb` (76 lines)
6. `spec/unit/adapter_spec.rb` (134 lines)

Total: 6 files, approximately 512 lines of code

---

## 4. Additional Context

### Iteration 2 Goals

This task is part of Iteration 2, which focuses on implementing the core Temporal workflow and activity components. All dependencies (I2.T2-I2.T5) are complete, meaning:
- ✅ I2.T2: AjWorkflow is implemented
- ✅ I2.T3: AjRunnerActivity is implemented
- ✅ I2.T4: Workflow ID builder helper is implemented
- ✅ I2.T5: Task queue resolver helper is implemented
- ✅ All unit tests are written

Your task is purely code quality enforcement - ensuring all code adheres to the Ruby style guide as enforced by Rubocop.

### Success Criteria

✅ `rake rubocop` exits with status 0 (zero offenses)
✅ All auto-correctable offenses are fixed
✅ Any manual fixes are applied correctly
✅ If `.rubocop.yml` is updated, changes are documented with comments
✅ Code maintains its functionality (no breaking changes)
✅ Code readability is maintained or improved

### Rubocop Command Reference

- `bundle exec rubocop` - Run all checks
- `bundle exec rubocop -A` - Auto-fix all safe offenses
- `bundle exec rubocop --list-target-files` - List files that will be checked
- `bundle exec rubocop lib/activejob/temporal/workflows/` - Check specific directory
- `bundle exec rubocop --format progress` - Show progress during check
- `rake rubocop` - Run via rake task (recommended)

### Known Exclusions in .rubocop.yml

Already excluded/disabled (no action needed):
- `vendor/**/*` - Bundled gems
- `tmp/**/*` - Temporary files
- `pkg/**/*` - Built gem files
- `spec/**/*` - Specs excluded from BlockLength check
- `Style/Documentation` - Class documentation not required
- `Naming/FileName` - Filename check disabled for `lib/activejob-temporal.rb`
- `Gemspec/DevelopmentDependencies` - Dev dependency check disabled
