# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I5.T8",
  "iteration_id": "I5",
  "iteration_goal": "Complete comprehensive documentation (README, API docs, migration guide), create example Rails app, finalize gemspec, prepare CHANGELOG, and ensure gem is ready for v0.1.0 release.",
  "description": "(Optional but recommended) Create a GitHub Actions CI workflow in .github/workflows/ci.yml to automate testing and quality checks. The workflow should: (1) Trigger on push and pull_request events. (2) Run on multiple Ruby versions (3.2, 3.3). (3) Set up Ruby, install dependencies, run Rubocop, run tests, build gem. (4) Upload coverage report (optional). Ensure workflow runs successfully on GitHub. Add CI badge to README if configured. This task is optional for v0.1 but highly recommended for open-source projects.",
  "agent_type_hint": "SetupAgent",
  "inputs": "GitHub Actions documentation, Ruby CI workflow examples, project structure",
  "target_files": [
    ".github/workflows/ci.yml",
    "README.md"
  ],
  "input_files": [
    "Gemfile",
    "Rakefile",
    "activejob-temporal.gemspec"
  ],
  "deliverables": "Working GitHub Actions CI workflow (optional)",
  "acceptance_criteria": ".github/workflows/ci.yml exists with all required jobs; Workflow triggers on push and pull_request; Workflow runs on Ruby 3.2 and 3.3 (matrix); Workflow runs bundle install, rubocop, rake spec, gem build; Workflow uploads coverage (optional); CI badge added to README (if workflow created); Manual test: Pushing to GitHub triggers workflow and it succeeds",
  "dependencies": [
    "I5.T7"
  ],
  "parallelizable": true,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: ci-cd-strategy (from 03_Verification_and_Glossary.md)

**CI/CD Strategy**

The gem uses GitHub Actions for continuous integration and delivery (optional but recommended for v0.1).

**CI Pipeline:**
1. **Trigger:** Push to main branch, pull requests
2. **Matrix:** Ruby 3.2, 3.3
3. **Steps:**
   - Set up Ruby environment
   - Install dependencies (`bundle install`)
   - Run linter (`rake rubocop`)
   - Run unit tests (`rake spec:unit`)
   - Run integration tests (`rake spec:integration` with Temporal test server)
   - Build gem (`gem build activejob-temporal.gemspec`)
   - Upload coverage report to Codecov or similar (optional)

**CD Pipeline (optional for v0.1):**
- Triggered on git tag creation (`v*`)
- Build and publish gem to RubyGems.org

**Quality Gates:**
- All tests must pass
- Rubocop must pass with zero offenses
- Code coverage must be >= 90%

**Badges:** Add CI status badge to README for visibility.

### Context: code-quality-gates (from 03_Verification_and_Glossary.md)

**Code Quality Gates**

The following quality gates must pass before code can be merged to the main branch:

1. **Rubocop:** Zero offenses
   - Command: `rake rubocop`
   - Configuration: `.rubocop.yml` with Ruby 3.2+ target, line length 120, custom excludes

2. **Test Coverage:** >= 90%
   - Tool: SimpleCov
   - Coverage types: Line coverage and branch coverage
   - Report format: HTML in `coverage/index.html`

3. **YARD Documentation:** All public APIs documented
   - Command: `rake yard`
   - No undocumented methods or classes
   - Generated docs in `doc/` directory

4. **Dependency Scanning:** No known vulnerabilities
   - Tool: `bundle audit` (optional but recommended)
   - Run in CI to fail on high-severity CVEs

5. **Payload Size Validation:** No payloads exceed `max_payload_size_kb`
   - Enforced at runtime via `Payload` module
   - Raises `ActiveJob::SerializationError` if exceeded

**Pre-commit Hooks (optional):** Developers can use Git hooks to run Rubocop and tests locally before pushing.

### Context: testing-levels (from 03_Verification_and_Glossary.md)

**Testing Strategy**

The gem employs a comprehensive testing strategy across multiple levels:

1. **Unit Tests**
   - Location: `spec/unit/`
   - Focus: Individual classes and modules in isolation
   - Mocking: External dependencies (Temporal client, Rails, ActiveRecord) are mocked/stubbed
   - Coverage target: >= 90% for each module
   - Run command: `rake spec:unit`

2. **Integration Tests**
   - Location: `spec/integration/`
   - Focus: End-to-end flows with real Temporal test server
   - Setup: Temporal test server started in `before(:suite)` hook
   - Scenarios tested:
     - Immediate job execution
     - Scheduled job execution (sleep)
     - Retry behavior (transient errors)
     - Discard behavior (non-retryable errors)
     - Cancellation with heartbeating
     - Search attributes persistence
   - Run command: `rake spec:integration`

3. **Manual Testing**
   - Location: `docs/worker_setup.md`, example Rails app
   - Focus: Real-world usage scenarios, developer experience
   - Checklist:
     - Start Temporal server
     - Configure adapter
     - Enqueue job
     - Start worker
     - Verify execution in Temporal UI
     - Cancel job
     - Verify search attributes

4. **Smoke Testing**
   - Performed after gem build
   - Steps:
     - Install gem locally: `gem install activejob-temporal-0.1.0.gem`
     - Require gem in irb: `require 'activejob-temporal'`
     - Verify version: `ActiveJob::Temporal::VERSION`

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `Rakefile`
    *   **Summary:** This file defines Rake tasks for the project, including `spec` (with `:unit` and `:integration` subtasks), `rubocop`, `yard`, and a `default` task that runs both rubocop and spec.
    *   **Recommendation:** Your GitHub Actions workflow MUST use these exact rake tasks: `rake rubocop`, `rake spec:unit`, `rake spec:integration`, and `gem build activejob-temporal.gemspec`. These are the authoritative commands for the project.
    *   **Note:** The `spec` task runs both unit and integration tests. For CI, you may want to run them separately to get better failure isolation.

*   **File:** `activejob-temporal.gemspec`
    *   **Summary:** This file defines the gem specification including dependencies and metadata. It specifies Ruby >= 3.2 as the minimum required version.
    *   **Recommendation:** Your CI matrix MUST test Ruby 3.2 and 3.3 as specified in the task. The gemspec already defines `spec.required_ruby_version = ">= 3.2"`, so these are the correct versions to test.
    *   **Note:** Development dependencies include `rake`, `rspec`, `rubocop`, `simplecov`, and `yard`. These will be installed by `bundle install` in CI.

*   **File:** `.rubocop.yml`
    *   **Summary:** This file configures Rubocop with Ruby 3.2 target, 120 character line length, and various custom rules. It excludes `tmp/`, `vendor/`, `pkg/`, and `examples/` directories.
    *   **Recommendation:** The `rake rubocop` command will use this configuration automatically. No need to pass additional flags in CI.

*   **File:** `spec/spec_helper.rb`
    *   **Summary:** This file configures RSpec and SimpleCov. SimpleCov is set up with branch coverage enabled and result merging for separate test runs (unit + integration).
    *   **Recommendation:** When running unit and integration tests separately in CI, SimpleCov will automatically merge the results. The coverage report will be generated in `coverage/index.html`.
    *   **Note:** The `TEST_SUITE` environment variable is used to distinguish between unit and integration test runs for SimpleCov result merging.

*   **File:** `README.md`
    *   **Summary:** The comprehensive README already has placeholder badges at the top (lines 5-6): Gem Version and License badges. These are the correct location to add a CI badge.
    *   **Recommendation:** If you create the CI workflow, you SHOULD add a GitHub Actions CI badge immediately after the existing badges on line 7. Use the standard format: `[![CI](https://github.com/temporalio/activejob-temporal/actions/workflows/ci.yml/badge.svg)](https://github.com/temporalio/activejob-temporal/actions/workflows/ci.yml)`
    *   **Note:** The README mentions that the gem is "under active development" (line 8), which makes CI even more valuable for catching regressions.

### Implementation Tips & Notes

*   **Tip:** For GitHub Actions Ruby setup, use the official `ruby/setup-ruby@v1` action. It has built-in caching for bundler dependencies, which will speed up CI runs.

*   **Tip:** The project uses SimpleCov with branch coverage enabled. The coverage report is generated in `coverage/` directory. You can optionally upload this to a service like Codecov or Coveralls, but this is marked as "optional" in the acceptance criteria.

*   **Tip:** For integration tests, the project requires a Temporal test server. Check if `spec/support/temporal_test_server.rb` handles this automatically or if the CI needs special setup. Based on the plan context, the test server should be started in RSpec's `before(:suite)` hook, so it should "just work" when running `rake spec:integration`.

*   **Warning:** The `.github/` directory does NOT exist yet. You MUST create both the directory structure (`.github/workflows/`) and the `ci.yml` file from scratch.

*   **Note:** The task is marked as "optional but recommended" in both the task description and acceptance criteria. However, since it's a good practice for open-source projects and will help catch issues early, you SHOULD implement it.

*   **Note:** The workflow should trigger on both `push` and `pull_request` events. For `push`, you probably want to limit it to the main branch (or `master` if that's what the repo uses). For `pull_request`, it should run on all PRs.

*   **Note:** The gemspec homepage points to `https://github.com/temporalio/activejob-temporal`, so the CI badge URL should use this repository path.

*   **Note:** Ruby 3.2 and 3.3 are the versions to test in the matrix. Don't add 3.1 or 3.4 unless explicitly requested.

*   **Note:** The workflow should have clear step names and use proper GitHub Actions syntax. Follow GitHub Actions best practices for Ruby projects.

*   **Security Note:** When uploading coverage reports, ensure you don't expose any sensitive information. SimpleCov's HTML reports should be safe, but if you use a coverage service, use their official GitHub Action and follow their security guidelines.

### Example CI Workflow Structure

Here's a recommended structure for the CI workflow:

```yaml
name: CI

on:
  push:
    branches: [ main, master ]
  pull_request:
    branches: [ main, master ]

jobs:
  test:
    name: Ruby ${{ matrix.ruby }} - ${{ matrix.test-suite }}
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        ruby: ['3.2', '3.3']
        test-suite: ['unit', 'integration']

    steps:
      - uses: actions/checkout@v4

      - name: Set up Ruby ${{ matrix.ruby }}
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ matrix.ruby }}
          bundler-cache: true

      - name: Run Rubocop
        run: bundle exec rake rubocop

      - name: Run ${{ matrix.test-suite }} tests
        run: bundle exec rake spec:${{ matrix.test-suite }}

      - name: Build gem
        run: gem build activejob-temporal.gemspec

      # Optional: Upload coverage
      - name: Upload coverage (optional)
        if: matrix.test-suite == 'integration' && matrix.ruby == '3.3'
        uses: actions/upload-artifact@v4
        with:
          name: coverage-report
          path: coverage/
```

**Note:** You may want to adjust this based on whether you want to run rubocop and gem build for every matrix combination or just once. The example above runs them for each combination for simplicity, but you could optimize by creating a separate job for linting.

### Acceptance Criteria Checklist

Make sure your implementation satisfies all of these:

- [ ] `.github/workflows/ci.yml` exists with all required jobs
- [ ] Workflow triggers on `push` and `pull_request` events
- [ ] Workflow runs on Ruby 3.2 and 3.3 (matrix)
- [ ] Workflow runs `bundle install` (via `ruby/setup-ruby` with `bundler-cache: true`)
- [ ] Workflow runs `rubocop` (via `rake rubocop` or `bundle exec rake rubocop`)
- [ ] Workflow runs tests (via `rake spec` or separate `rake spec:unit` and `rake spec:integration`)
- [ ] Workflow runs `gem build activejob-temporal.gemspec`
- [ ] Workflow uploads coverage report (optional, but nice to have)
- [ ] CI badge added to README (after line 6, before line 8)
- [ ] Manual test: Pushing to GitHub triggers workflow and it succeeds (this will happen after the workflow is merged)

### Final Notes

This is an optional task, but implementing it will significantly improve the project's maintainability and give confidence to potential users that the gem is well-tested. Since all the required tasks (I5.T1-I5.T7) are complete, the gem is ready for CI setup.

Good luck with the implementation!
