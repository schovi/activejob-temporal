# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I3.T7",
  "iteration_id": "I3",
  "iteration_goal": "Implement the ActiveJob adapter (TemporalAdapter) that integrates with Rails, and the cancellation API. This connects all previous components to enable actual job enqueue and cancellation.",
  "description": "Run `rake rubocop` on all code written in Iteration 3 (adapter, cancellation). Fix any Rubocop offenses. Update `.rubocop.yml` if needed. Acceptance: `rake rubocop` passes with zero offenses.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Rubocop configuration, code from I3.T1-I3.T5",
  "target_files": [
    "lib/activejob/temporal/adapter.rb",
    "lib/activejob/temporal/cancel.rb",
    "spec/unit/adapter_spec.rb",
    "spec/unit/cancel_spec.rb",
    ".rubocop.yml"
  ],
  "input_files": [
    "lib/activejob/temporal/adapter.rb",
    "lib/activejob/temporal/cancel.rb",
    "spec/unit/adapter_spec.rb",
    "spec/unit/cancel_spec.rb",
    ".rubocop.yml"
  ],
  "deliverables": "Clean code passing Rubocop checks",
  "acceptance_criteria": "`rake rubocop` exits with status 0 (zero offenses); All auto-correctable offenses are fixed; Any manual fixes are applied; If `.rubocop.yml` is updated, changes are documented",
  "dependencies": [
    "I3.T1",
    "I3.T2",
    "I3.T3",
    "I3.T5"
  ],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: Iteration 3 Overview (from 02_Iteration_I3.md)

This task is part of Iteration 3, which focuses on implementing the ActiveJob adapter and cancellation API.

**Iteration Goal:** Implement the ActiveJob adapter (`TemporalAdapter`) that integrates with Rails, and the cancellation API. This connects all previous components to enable actual job enqueue and cancellation.

**Prerequisites:**
- I1 (Foundation modules: Configuration, Client, Payload, RetryMapper, SearchAttributes, Logger)
- I2 (Workflow and Activity implementation: AjWorkflow, AjRunnerActivity)

**Iteration 3 includes these tasks:**
- I3.T1: Implement TemporalAdapter Core (enqueue method)
- I3.T2: Implement enqueue_at method (scheduled jobs)
- I3.T3: Implement enqueue_after_transaction_commit? method
- I3.T4: Register TemporalAdapter with ActiveJob
- I3.T5: Implement Cancellation API
- I3.T6: Update cancellation sequence diagram
- **I3.T7: Run Rubocop and fix style issues (CURRENT TASK)**
- I3.T8: Run unit tests and verify coverage

### Context: Code Quality Requirements (from 03_Verification_and_Glossary.md)

**Code Quality Gates:**

The project uses several quality gates to ensure code quality:

1. **Rubocop**: Enforces Ruby style guide
   - Configuration: `.rubocop.yml`
   - Target Ruby Version: 3.2
   - Line Length: Max 120 characters
   - Block Length: Max 25 (excluded in spec files)
   - Method Length: Max 20
   - Module Length: Max 200
   - String Literals: Enforced double quotes

2. **SimpleCov Coverage**: >= 90% test coverage required

3. **YARD Documentation**: Public APIs must be documented

4. **Dependency Scanning**: Dependencies must be up-to-date and secure

### Context: Project Ruby Configuration

**Ruby Version Requirements:**
- Minimum: Ruby >= 3.2
- Rails >= 6.1
- Uses frozen string literals in all files

**Style Preferences:**
- Double-quoted strings (`EnforcedStyle: double_quotes`)
- NewCops enabled
- Documentation checks disabled (test framework and gem code)

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

#### File: `.rubocop.yml`
- **Summary:** This file contains the project's Rubocop configuration with sensible defaults for a Ruby gem project.
- **Current Configuration:**
  - Target Ruby Version: 3.2
  - Line Length: Max 120 characters
  - Block Length: Max 25 (spec files excluded)
  - Method Length: Max 20
  - Module Length: Max 200
  - Style/Documentation: Disabled (common for gems)
  - Style/StringLiterals: EnforcedStyle is `double_quotes`
  - Naming/FileName: Excludes `lib/activejob-temporal.rb`
  - Gemspec/DevelopmentDependencies: Disabled
- **Recommendation:** You SHOULD NOT need to modify this file unless there are legitimate style conflicts that cannot be auto-corrected. If you do modify it, you MUST add comments explaining the rationale.

#### File: `lib/activejob/temporal/adapter.rb`
- **Summary:** This is the main ActiveJob adapter implementation that bridges ActiveJob with Temporal workflows. It includes the `TemporalAdapter` class with `enqueue`, `enqueue_at`, and `enqueue_after_transaction_commit?` methods.
- **Current State:** 146 lines of code implementing the full adapter interface
- **Key Features:**
  - Deterministic workflow ID generation
  - Task queue resolution with optional prefix
  - Payload serialization and validation
  - Search attributes attachment
  - Retry policy mapping
  - Comprehensive error handling for duplicate workflows and connection failures
- **Recommendation:** This file should already be well-structured. You SHOULD run rubocop and fix any auto-correctable offenses first, then review any remaining manual fixes needed.

#### File: `lib/activejob/temporal/cancel.rb`
- **Summary:** This module provides the cancellation API for cancelling running Temporal workflows.
- **Current State:** 70 lines of code implementing best-effort cancellation
- **Key Features:**
  - Workflow ID building from job class and job ID
  - Cancellation request sending via Temporal client
  - Graceful handling of "not found" errors
  - Comprehensive logging of cancellation events
- **Recommendation:** This file is relatively short and should have minimal style issues. You SHOULD check for proper error handling documentation.

#### File: `spec/unit/adapter_spec.rb`
- **Summary:** Comprehensive unit tests for the TemporalAdapter covering all enqueue scenarios.
- **Current State:** 334 lines of well-structured RSpec tests
- **Test Coverage:**
  - Workflow ID building and determinism
  - Task queue resolution with/without prefix
  - Enqueue method with all dependencies mocked
  - Enqueue_at for scheduled jobs
  - Transaction-aware enqueuing
  - ActiveJob adapter registration
- **Recommendation:** Spec files are excluded from BlockLength checks, but other style rules still apply. You SHOULD ensure consistent formatting and proper use of RSpec DSL.

#### File: `spec/unit/cancel_spec.rb`
- **Summary:** Unit tests for the cancellation API covering success and error scenarios.
- **Current State:** 116 lines of RSpec tests with proper mocking
- **Test Coverage:**
  - Successful cancellation
  - Workflow not found handling
  - Other RPC error propagation
  - Proper logging verification
- **Recommendation:** This spec file includes a mock for `Temporalio::Error::RPCError` which is a good pattern. Ensure this doesn't trigger any Rubocop warnings.

#### File: `Rakefile`
- **Summary:** The project's Rake configuration with tasks for running tests, Rubocop, and generating documentation.
- **Key Tasks:**
  - `rake spec`: Run RSpec tests
  - `rake rubocop`: Run Rubocop linter
  - `rake yard`: Generate YARD documentation
  - `rake default`: Runs both rubocop and spec
- **Recommendation:** You SHOULD use `rake rubocop` or `rake rubocop -a` for auto-correction. The rake task is properly configured to work with the project's Ruby environment.

### Implementation Tips & Notes

#### Tip 1: Ruby Environment Issues
- **Issue:** The project has Ruby version conflicts. The system Ruby (2.6.10) is being used instead of the project's required Ruby 3.3.5.
- **Solution:** You SHOULD use the vendor bundle to run rubocop: `vendor/bundle/ruby/3.3.0/bin/rubocop [files]` or ensure the correct Ruby version is active before running `rake rubocop`.
- **Alternative:** You MAY need to use a Ruby version manager (like RVM or rbenv) to switch to Ruby 3.3.5 first.

#### Tip 2: Auto-Correction Strategy
- **Best Practice:** Always run rubocop with the `-a` or `--auto-correct` flag first to fix all auto-correctable offenses.
- **Command:** `rake rubocop -a` or `vendor/bundle/ruby/3.3.0/bin/rubocop -a [files]`
- **After Auto-Correction:** Review the changes to ensure they don't break functionality, then commit.

#### Tip 3: Common Rubocop Offenses to Watch For
Based on the code I reviewed, potential issues might include:
- **Line Length:** Some lines in `adapter_spec.rb` might exceed 120 characters (especially in expect assertions)
- **Method Length:** Private methods in `adapter.rb` might be close to the 20-line limit
- **Variable Naming:** Ensure snake_case for all variables
- **Trailing Whitespace:** Common in test files
- **String Literals:** Ensure all strings use double quotes, not single quotes (unless it's a special case)

#### Tip 4: Files That Should Pass Easily
These files are likely already compliant or very close:
- `.rubocop.yml` (configuration file, not checked)
- `lib/activejob/temporal/cancel.rb` (short, simple module)
- `spec/unit/cancel_spec.rb` (well-structured tests)

#### Tip 5: Files That May Need Attention
These files might have style issues due to complexity:
- `lib/activejob/temporal/adapter.rb` (146 lines, multiple private methods)
- `spec/unit/adapter_spec.rb` (334 lines, many test scenarios with long expectations)

#### Warning: Do Not Break Functionality
- **Critical:** While fixing style issues, you MUST NOT change the logic or behavior of the code.
- **Test After Changes:** After applying auto-corrections, you SHOULD run `rake spec` to ensure all tests still pass.
- **If Tests Fail:** Revert the problematic change and apply manual fixes instead.

### Execution Steps Recommendation

Based on my analysis, here's the recommended approach:

1. **Ensure Correct Ruby Environment:**
   ```bash
   # Verify Ruby version
   ruby --version  # Should be 3.3.5 or similar

   # If not, use RVM or rbenv to switch
   # rvm use 3.3.5
   # OR
   # rbenv local 3.3.5
   ```

2. **Run Rubocop on I3 Files:**
   ```bash
   # First, just check for offenses
   rake rubocop

   # Or check specific I3 files
   vendor/bundle/ruby/3.3.0/bin/rubocop \
     lib/activejob/temporal/adapter.rb \
     lib/activejob/temporal/cancel.rb \
     spec/unit/adapter_spec.rb \
     spec/unit/cancel_spec.rb
   ```

3. **Auto-Correct All Possible Offenses:**
   ```bash
   # Let rubocop fix auto-correctable issues
   rake rubocop -a

   # Or for specific files
   vendor/bundle/ruby/3.3.0/bin/rubocop -a \
     lib/activejob/temporal/adapter.rb \
     lib/activejob/temporal/cancel.rb \
     spec/unit/adapter_spec.rb \
     spec/unit/cancel_spec.rb
   ```

4. **Review and Commit Auto-Corrections:**
   ```bash
   git diff  # Review changes
   git add [files]
   git commit -m "style: auto-correct rubocop offenses in I3 files"
   ```

5. **Manually Fix Remaining Offenses:**
   - Read each remaining offense carefully
   - Apply fixes that don't change behavior
   - If an offense is unavoidable (e.g., method complexity), consider adding a rubocop disable comment with justification

6. **Verify Tests Still Pass:**
   ```bash
   rake spec
   ```

7. **Final Rubocop Check:**
   ```bash
   rake rubocop
   # Exit code should be 0
   ```

8. **Document Any Configuration Changes:**
   - If you modified `.rubocop.yml`, add comments explaining why
   - Update this briefing or create a note for the team

### Known Issues to Address

Based on typical patterns in the codebase:

1. **Long Test Expectations:** The adapter_spec.rb file likely has some long expectation lines. You may need to break these into multiple lines or extract to variables.

2. **Private Method Documentation:** Private methods in adapter.rb have YARD-style comments, which is good, but ensure they don't trigger Documentation cop if it's re-enabled.

3. **Mock Class Definitions:** The cancel_spec.rb defines mock classes for Temporalio errors. Ensure these don't trigger naming convention warnings.

4. **String Quotes:** Verify all strings use double quotes consistently throughout the I3 files.

### Success Criteria Checklist

To complete this task successfully, you MUST achieve:

- [ ] `rake rubocop` exits with status 0 (zero offenses)
- [ ] All auto-correctable offenses are fixed
- [ ] Any manual fixes are applied correctly
- [ ] No functionality is broken (all tests still pass)
- [ ] If `.rubocop.yml` is updated, changes are documented with comments
- [ ] All four I3 files pass rubocop individually:
  - [ ] `lib/activejob/temporal/adapter.rb`
  - [ ] `lib/activejob/temporal/cancel.rb`
  - [ ] `spec/unit/adapter_spec.rb`
  - [ ] `spec/unit/cancel_spec.rb`

---

## 4. Additional Context

### Project Structure Overview
```
activejob-temporal/
├── lib/
│   └── activejob/
│       └── temporal/
│           ├── adapter.rb         # I3.T1-T3 (Main adapter implementation)
│           ├── cancel.rb          # I3.T5 (Cancellation API)
│           ├── client.rb          # I1.T4 (Temporal client wrapper)
│           ├── payload.rb         # I1.T5 (Payload serializer)
│           ├── retry_mapper.rb    # I1.T6 (Retry policy mapper)
│           ├── search_attributes.rb # I1.T7 (Search attributes builder)
│           └── logger.rb          # I1.T8 (Structured logger)
├── spec/
│   └── unit/
│       ├── adapter_spec.rb        # I3.T1-T4 tests
│       └── cancel_spec.rb         # I3.T5 tests
├── .rubocop.yml                   # Rubocop configuration
├── Rakefile                       # Task definitions
└── Gemfile                        # Dependencies
```

### Related Documentation
- Ruby Style Guide: https://rubystyle.guide/
- Rubocop Documentation: https://docs.rubocop.org/
- Project-specific style guidelines: See `.rubocop.yml` for customizations

---

**End of Task Briefing Package**
