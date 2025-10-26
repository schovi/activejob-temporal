# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I1.T9",
  "iteration_id": "I1",
  "iteration_goal": "Establish project structure, dependencies, and foundational modules (configuration, client, payload handling). Generate core architecture diagrams.",
  "description": "Run `rake rubocop` on all code written in Iteration 1. Fix any Rubocop offenses (style violations, complexity warnings, etc.) in all lib/ and spec/ files. Ensure code adheres to Ruby style guide. If necessary, update `.rubocop.yml` with reasonable exceptions (e.g., increase max line length to 120 if needed, disable specific cops with justification in comments). Commit fixes. Acceptance: `rake rubocop` passes with zero offenses.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Rubocop configuration (`.rubocop.yml`), Ruby style guide, code from I1.T3-I1.T8",
  "target_files": [
    "lib/activejob/temporal.rb",
    "lib/activejob/temporal/client.rb",
    "lib/activejob/temporal/payload.rb",
    "lib/activejob/temporal/retry_mapper.rb",
    "lib/activejob/temporal/search_attributes.rb",
    "lib/activejob/temporal/logger.rb",
    "spec/unit/*.rb",
    ".rubocop.yml"
  ],
  "input_files": [
    "lib/activejob/temporal.rb",
    "lib/activejob/temporal/client.rb",
    "lib/activejob/temporal/payload.rb",
    "lib/activejob/temporal/retry_mapper.rb",
    "lib/activejob/temporal/search_attributes.rb",
    "lib/activejob/temporal/logger.rb",
    "spec/unit/*.rb",
    ".rubocop.yml"
  ],
  "deliverables": "Clean code passing Rubocop checks",
  "acceptance_criteria": "`rake rubocop` exits with status 0 (zero offenses); All auto-correctable offenses are fixed; Any manual fixes are applied (e.g., method complexity reduced, long lines broken); If `.rubocop.yml` is updated, changes are documented with comments explaining exceptions",
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

### Context: Non-Functional Requirements - Maintainability (Architecture)

The project has strict quality requirements for code maintainability:

- **Clean Code:** Follow Ruby style guide conventions (enforced via Rubocop)
- **Testability:** >= 90% code coverage requirement
- **Linting:** All code must pass Rubocop with zero offenses

### Context: Quality Gates (Plan)

From the verification strategy:

**Code Quality Gates:**
- **Rubocop:** Style checking with Ruby style guide compliance
- Configured in `.rubocop.yml` with sensible defaults
- Target Ruby version: >= 3.2
- Max line length: 120 characters
- Documentation requirement: Disabled for v0.1

**Iteration 1 Quality Check (I1.T9):**
This task specifically ensures that all foundational modules created in Iteration 1 pass Rubocop checks before moving to Iteration 2 (workflow/activity implementation).

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `.rubocop.yml`
    *   **Summary:** This file contains the project's RuboCop configuration with sensible defaults already in place.
    *   **Current Settings:**
        - Target Ruby version: 3.2
        - Max line length: 120 characters
        - Block length: Max 25 (with spec exclusion)
        - Method length: Max 20
        - Module length: Max 200
        - Documentation: Disabled
        - String literals: Double quotes enforced
        - Excludes: tmp/**, vendor/**, pkg/**
    *   **Recommendation:** You SHOULD review this configuration first. The settings are already quite reasonable for this project.

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** Main entrypoint module with Configuration class and module-level methods (config, client, configure).
    *   **Current State:** Contains ~90 lines including Configuration class with validation logic.
    *   **Potential Issues:**
        - The Configuration class is relatively complex with custom setters
        - Ensure no method length violations in `ensure_positive_duration!` or `default_logger`
    *   **Recommendation:** This is a core file - any changes here should maintain backward compatibility.

*   **File:** `lib/activejob/temporal/client.rb`
    *   **Summary:** Temporal client connection wrapper with TLS support and error handling.
    *   **Current State:** Module with `build`, `connection_options`, and `tls_options` methods.
    *   **Potential Issues:**
        - Uses `module_function` pattern
        - Has private class methods
        - Error message formatting with heredoc/interpolation
    *   **Recommendation:** Pay attention to complexity in `connection_options` and `tls_options` - they build nested hashes.

*   **File:** `lib/activejob/temporal/payload.rb`
    *   **Summary:** Payload serialization/deserialization for ActiveJob arguments with size limits.
    *   **Current State:** Module using `extend self` pattern with public and private methods.
    *   **Potential Issues:**
        - Complex conditional logic in `iso8601_timestamp`
        - String formatting in `enforce_payload_size!`
    *   **Recommendation:** This file has complex logic - watch for cyclomatic complexity and method length violations.

*   **File:** `lib/activejob/temporal/retry_mapper.rb`
    *   **Summary:** Maps ActiveJob retry_on/discard_on to Temporal RetryPolicy.
    *   **Current State:** Large module (~162 lines) with many private helper methods.
    *   **Potential Issues:**
        - Module is approaching the 200-line limit
        - Complex logic with metaprogramming (binding inspection)
        - Many private helper methods
    *   **Recommendation:** This is the most complex module. It may trigger:
        - Module length warnings (currently 162 lines, limit is 200)
        - Method complexity warnings due to binding inspection logic
        - You MAY need to suppress specific cops here with inline comments if complexity is inherent to the algorithm.

*   **File:** `lib/activejob/temporal/search_attributes.rb`
    *   **Summary:** Builds Temporal Search Attributes from ActiveJob metadata.
    *   **Current State:** Simple module (~33 lines) with one public method.
    *   **Potential Issues:** None expected - this is a straightforward builder.
    *   **Recommendation:** This file should pass cleanly.

*   **File:** `lib/activejob/temporal/logger.rb`
    *   **Summary:** Structured JSON logging helper with semantic logger support.
    *   **Current State:** Module (~73 lines) with public and private methods.
    *   **Potential Issues:**
        - Method count (info, warn, error, log, build_payload, etc.)
        - Conditional logic in `log` method
    *   **Recommendation:** Should be clean, but verify no method length issues in `log`.

*   **File:** `spec/unit/*.rb`
    *   **Summary:** Unit tests for all modules created in Iteration 1.
    *   **Current State:** Six spec files (configuration, client, logger, payload, retry_mapper, search_attributes).
    *   **Potential Issues:**
        - Specs are excluded from BlockLength metric
        - Should have no violations due to exclusion
    *   **Recommendation:** These should be clean due to spec exclusions in .rubocop.yml.

### Implementation Tips & Notes

*   **Tip #1 - Running RuboCop:** There appears to be a bundler/gem compatibility issue in the environment. You SHOULD try these approaches in order:
    1. `vendor/bundle/ruby/3.3.0/bin/rubocop` (direct execution from vendored gems)
    2. Use the vendored RuboCop to avoid bundler issues
    3. If that fails, try `tools/lint.sh` script if it exists

*   **Tip #2 - Auto-Correction:** RuboCop supports auto-correction for many offenses. You SHOULD run:
    - `rubocop --auto-correct-all` or `rubocop -A` to automatically fix simple style issues
    - Then manually review and fix remaining offenses

*   **Tip #3 - Expected Violations:** Based on code review, the most likely violations are:
    - **RetryMapper module:** May have method complexity issues due to metaprogramming logic
    - **Payload module:** May have method length issues in `iso8601_timestamp` or `enforce_payload_size!`
    - **Configuration class:** May have method length issues in initialization

*   **Tip #4 - Acceptable Exceptions:** If you need to add RuboCop exceptions:
    - **DO** use inline comments for specific violations: `# rubocop:disable Style/GuardClause`
    - **DO** add comments explaining why the exception is needed
    - **DO NOT** globally disable cops unless absolutely necessary
    - **DO** keep exceptions minimal and well-justified

*   **Tip #5 - Documentation:** The current `.rubocop.yml` already disables `Style/Documentation`, so you do NOT need to add YARD comments to pass RuboCop. However, the next iteration (I1.T10) will verify coverage, so keep that in mind.

*   **Warning #1:** The `retry_mapper.rb` file uses Ruby metaprogramming with `binding.local_variable_get`. This is inherently complex. If RuboCop complains about cyclomatic complexity or method length:
    - First, try to refactor if possible
    - If refactoring breaks functionality, add inline disable comments with clear justification
    - Document that this complexity is essential for introspecting ActiveJob's retry DSL

*   **Warning #2:** Do NOT modify the functional logic of any files to satisfy RuboCop. Style fixes are acceptable, but breaking working code to reduce complexity is NOT. If a method is legitimately complex, use inline disable comments.

### Files Requiring Attention (Prioritized)

1. **HIGH PRIORITY:** `lib/activejob/temporal/retry_mapper.rb` - Most complex, most likely to have violations
2. **MEDIUM PRIORITY:** `lib/activejob/temporal/payload.rb` - Complex conditional logic
3. **MEDIUM PRIORITY:** `lib/activejob/temporal.rb` - Configuration class has custom setters
4. **LOW PRIORITY:** Other lib files - Likely clean
5. **LOW PRIORITY:** Spec files - Already excluded from most metrics

### Execution Strategy

1. **Run RuboCop:** First, get the complete list of offenses by running rubocop
2. **Auto-Correct:** Run auto-correction for trivial fixes
3. **Manual Review:** Review remaining offenses and decide:
   - Can the code be refactored? → Refactor
   - Is the complexity inherent? → Add inline disable with justification
4. **Verify:** Run rubocop again to confirm zero offenses
5. **Document:** If you added any exceptions to `.rubocop.yml`, add comments explaining why

### Success Criteria Checklist

- [ ] RuboCop runs successfully (no bundler errors)
- [ ] All auto-correctable offenses are fixed
- [ ] All remaining offenses are either fixed or suppressed with inline comments
- [ ] Any suppressed offenses have clear justification comments
- [ ] `.rubocop.yml` is updated if needed (with documented reasons)
- [ ] `rake rubocop` or equivalent exits with status 0
- [ ] No functional logic is changed (only style fixes)
- [ ] Code still passes existing tests (verify with `rake spec` if possible)

---

**END OF BRIEFING PACKAGE**
