# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I6.T9",
  "iteration_id": "I6",
  "iteration_goal": "Enhance Version 2 with robust validation, better error handling, and comprehensive documentation from Version 1 analysis while maintaining Version 2's superior architecture.",
  "description": "Run `rake rubocop` on all code modified in Iteration 6 to ensure Ruby style compliance. Fix any Rubocop offenses (style violations, complexity warnings, line length, etc.) in all lib/ and spec/ files touched by I6.T1-I6.T8. Common issues to address: (1) Long methods (extract private helper methods if needed); (2) High cyclomatic complexity (simplify conditionals, extract logic); (3) Long lines (break at 120 characters or use configured limit); (4) Missing frozen_string_literal comments (add to top of new files); (5) Documentation cops (ensure all public methods have YARD docs - already covered in I6.T7). If necessary, update `.rubocop.yml` with reasonable exceptions (e.g., allow slightly longer methods for validation logic, disable specific cops with inline comments if justified). Commit Rubocop fixes separately from feature commits for clean git history. Acceptance: `rake rubocop` passes with zero offenses on all modified files.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Rubocop configuration (`.rubocop.yml`), Ruby style guide, code from I6.T1-I6.T8",
  "target_files": [
    "lib/activejob/temporal.rb",
    "lib/activejob/temporal/cancel.rb",
    "lib/activejob/temporal/payload.rb",
    "lib/activejob/temporal/adapter.rb",
    "spec/unit/configuration_spec.rb",
    "spec/unit/cancel_spec.rb",
    "spec/unit/payload_spec.rb",
    ".rubocop.yml"
  ],
  "input_files": [
    "lib/activejob/temporal.rb",
    "lib/activejob/temporal/cancel.rb",
    "lib/activejob/temporal/payload.rb",
    "lib/activejob/temporal/adapter.rb",
    "spec/unit/configuration_spec.rb",
    "spec/unit/cancel_spec.rb",
    "spec/unit/payload_spec.rb",
    ".rubocop.yml"
  ],
  "deliverables": "Clean code passing Rubocop checks with zero offenses",
  "acceptance_criteria": "`rake rubocop` exits with status 0 (zero offenses) on all files in lib/activejob/temporal/; All auto-correctable offenses are fixed with `rubocop -a`; Manual fixes applied for: method complexity (extract helpers), long lines (break appropriately), missing docs (ensure YARD present); All new files have `# frozen_string_literal: true` at top; If `.rubocop.yml` is updated, changes documented with comments explaining rationale (e.g., '# Allow 150-line validation methods due to comprehensive error checking'); No rubocop:disable comments without explanation; Code maintains readability after Rubocop fixes (no awkward line breaks just to satisfy line length)",
  "dependencies": [
    "I6.T1",
    "I6.T2",
    "I6.T3",
    "I6.T4",
    "I6.T7",
    "I6.T8"
  ],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: Rubocop Configuration Philosophy (from .rubocop.yml analysis)

The project uses Rubocop with sensible defaults tailored for the activejob-temporal gem:

- **Target Ruby Version**: 3.2
- **Line Length**: Max 120 characters (not the default 80)
- **Method Length**: Max 20 lines
- **Block Length**: Max 25 lines (but excluded for spec files)
- **Module Length**: Max 200 lines
- **Class Length**: Max 120 lines
- **ABC Size**: Max 22 (complexity metric)
- **Cyclomatic Complexity**: Max 10
- **Perceived Complexity**: Max 10
- **String Literals**: Double quotes enforced
- **Documentation**: Disabled (Style/Documentation cop is off)
- **Exclusions**: tmp/, vendor/, pkg/, examples/ are excluded from checks

### Context: Code Quality Standards (from Iteration 6 goals)

This iteration (I6) focuses on enhancing the codebase with:

1. **Validation**: All configuration settings must be validated with proper error messages
2. **Error Handling**: Better exception handling with custom exception classes
3. **Documentation**: Comprehensive YARD documentation for all public APIs
4. **Ruby Style**: Code must adhere to Ruby style guide and pass Rubocop checks

### Context: Files Modified in Iteration 6 (from I6.T1-I6.T8)

The following files were modified or created in Iteration 6 and are the primary targets for this task:

**Core Implementation Files:**
- `lib/activejob/temporal.rb` - Enhanced with `ConfigurationError`, `WorkflowNotFoundError`, `TemporalConnectionError` exception classes and comprehensive validation methods in the Configuration class
- `lib/activejob/temporal/cancel.rb` - Enhanced with query-based workflow discovery and better error handling
- `lib/activejob/temporal/payload.rb` - Enhanced with payload size validation
- `lib/activejob/temporal/adapter.rb` - Minor updates to use new configuration options

**Test Files:**
- `spec/unit/configuration_spec.rb` - New tests for validation methods
- `spec/unit/cancel_spec.rb` - Enhanced tests for workflow discovery
- `spec/unit/payload_spec.rb` - New tests for size validation

**Configuration:**
- `.rubocop.yml` - May need updates to accommodate complex validation logic

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `.rubocop.yml`
    *   **Summary:** This file contains the Rubocop configuration with relaxed limits suitable for production code. Line length is 120 chars, method length is 20 lines, and documentation cop is disabled.
    *   **Recommendation:** You SHOULD review this configuration before running Rubocop. If validation methods in `lib/activejob/temporal.rb` exceed method length limits, consider adding targeted exceptions with clear comments explaining why.

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** This is the main module file that contains the Configuration class with validation methods added in I6.T1, I6.T2, and I6.T8. It has grown to 460 lines and includes multiple validation methods (validate_target!, validate_namespace!, validate_timeouts!, validate_retry_settings!, validate_payload_size!, validate_worker_concurrency!).
    *   **Recommendation:** This file is likely to have Rubocop violations due to its size and complexity. The Configuration class (lines 99-329) and its validation methods are the most likely candidates for issues. You MUST ensure:
        - All validation methods have proper YARD documentation (already done in I6.T7)
        - Method complexity metrics are satisfied (extract helper methods if needed)
        - Line length does not exceed 120 characters
        - All private methods are marked with `# @api private` in YARD comments
        - The frozen_string_literal comment is present at the top

*   **File:** `lib/activejob/temporal/cancel.rb`
    *   **Summary:** This file implements the cancellation API with query-based workflow discovery added in I6.T3. It includes methods for querying running and closed workflows, building queries, and logging.
    *   **Recommendation:** Check for:
        - Long string literals in query methods (lines 119-126) - these may need breaking
        - Cyclomatic complexity in the `cancel` method (lines 64-81) with its case statement
        - Ensure all methods have YARD docs (already done in I6.T7)

*   **File:** `lib/activejob/temporal/payload.rb`
    *   **Summary:** This file handles payload serialization with size validation added in I6.T4. The `enforce_payload_size!` method uses format strings and calculations.
    *   **Recommendation:** Check for:
        - Long lines in the `enforce_payload_size!` method (lines 180-194)
        - The format call may have long argument lists
        - Ensure error messages are well-formatted

*   **File:** `lib/activejob/temporal/adapter.rb`
    *   **Summary:** This file implements the ActiveJob adapter with comprehensive YARD documentation. It's well-structured and already follows Ruby best practices.
    *   **Recommendation:** This file should have minimal Rubocop issues. Only check for any new violations introduced by I6.T7 documentation additions.

*   **File:** `Rakefile`
    *   **Summary:** Contains task definitions for running Rubocop, RSpec, and YARD. The default task runs both `rubocop` and `spec`.
    *   **Recommendation:** You SHOULD use `rake rubocop` to run the style checks. For auto-fixing, use `rubocop -a` directly.

### Implementation Tips & Notes

*   **Tip:** Start by running `rake rubocop` to see the full list of violations. The output will show you the exact file, line number, and cop name for each offense.

*   **Tip:** Use `rubocop -a` to auto-fix simple offenses like string quotes, trailing whitespace, and indentation. This should fix the majority of issues.

*   **Tip:** For method length violations in validation methods, consider extracting error message formatting into private helper methods. For example:
    ```ruby
    # Before
    def validate_target!
      target_regex = /^[\w.-]+:\d{1,5}$/
      return if target&.match?(target_regex)

      raise ConfigurationError, "target must match host:port format (e.g., 'localhost:7233'), got: #{target.inspect}"
    end

    # After (if needed)
    def validate_target!
      target_regex = /^[\w.-]+:\d{1,5}$/
      return if target&.match?(target_regex)

      raise_target_format_error
    end

    def raise_target_format_error
      raise ConfigurationError,
            "target must match host:port format (e.g., 'localhost:7233'), got: #{target.inspect}"
    end
    ```

*   **Note:** The Configuration class validation methods are legitimately complex due to comprehensive error checking. If Rubocop flags method complexity (ABC size, cyclomatic complexity), you have two options:
    1. Extract helper methods to reduce complexity (preferred)
    2. Add targeted Rubocop exclusions with clear comments explaining the rationale

*   **Note:** String concatenation in the `closed_workflows_query` method (lines 125-126 in cancel.rb) uses `\` for multi-line strings. This is correct Ruby syntax and should not need changes.

*   **Warning:** The task explicitly states "Commit Rubocop fixes separately from feature commits for clean git history." After fixing all violations, you MUST create a dedicated commit with a message like "style: fix Rubocop violations in I6 code".

*   **Warning:** If you need to update `.rubocop.yml` to add exceptions, you MUST add clear comments explaining why. Example:
    ```yaml
    # Validation methods require comprehensive error checking
    # which legitimately increases method length
    Metrics/MethodLength:
      Exclude:
        - 'lib/activejob/temporal.rb' # Configuration validation methods
    ```

*   **Warning:** The acceptance criteria explicitly states "No rubocop:disable comments without explanation." If you must add inline `# rubocop:disable` comments, follow them with a clear explanation on the same or next line.

### Common Rubocop Violations and Fixes

Based on the code I reviewed, here are the most likely violations you'll encounter:

1. **Metrics/MethodLength**: The validation methods in Configuration class may exceed 20 lines
   - **Fix:** Extract helper methods or add exception to .rubocop.yml

2. **Layout/LineLength**: Error messages and query strings may exceed 120 characters
   - **Fix:** Break long strings across multiple lines with proper indentation

3. **Metrics/AbcSize**: Complex validation logic may exceed ABC size limit
   - **Fix:** Extract helper methods to reduce complexity

4. **Metrics/CyclomaticComplexity**: The `cancel` method's case statement may be flagged
   - **Fix:** This is acceptable complexity for clarity; may need exception

5. **Style/FormatStringToken**: The `format` call in `enforce_payload_size!` may be flagged
   - **Fix:** Ensure you're using annotated format strings with named placeholders

6. **Naming/VariableName**: Ensure all variable names follow Ruby conventions
   - **Fix:** Auto-fixed by `rubocop -a`

### Execution Strategy

1. **Run Initial Analysis:**
   ```bash
   rake rubocop
   ```
   This will show you all violations. Take note of the most common ones.

2. **Auto-Fix Simple Issues:**
   ```bash
   rubocop -a
   ```
   This handles formatting, quotes, whitespace, etc.

3. **Manual Fixes for Complex Issues:**
   - Address method length violations by extracting helpers
   - Break long lines at logical points
   - Reduce complexity by simplifying conditionals

4. **Update .rubocop.yml if Needed:**
   - Only add exceptions for legitimately complex code
   - Always add explanatory comments

5. **Verify All Offenses Fixed:**
   ```bash
   rake rubocop
   ```
   Should exit with status 0.

6. **Commit Changes:**
   ```bash
   git add -p  # Review each change
   git commit -m "style: fix Rubocop violations in I6 code"
   ```

### Files to Focus On

**Priority 1** (most likely to have violations):
- `lib/activejob/temporal.rb` - Large file with validation logic
- `spec/unit/configuration_spec.rb` - New tests

**Priority 2** (check carefully):
- `lib/activejob/temporal/cancel.rb` - Query string formatting
- `lib/activejob/temporal/payload.rb` - Error message formatting

**Priority 3** (minimal changes expected):
- `lib/activejob/temporal/adapter.rb` - Already well-formatted
- `spec/unit/cancel_spec.rb` - Spec files have relaxed rules
- `spec/unit/payload_spec.rb` - Spec files have relaxed rules
