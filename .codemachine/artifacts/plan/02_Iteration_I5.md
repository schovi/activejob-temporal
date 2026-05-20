# Project Plan: activejob-temporal Gem - Iteration 5

---

<!-- anchor: iteration-5-plan -->
### Iteration 5: Documentation, Examples & Release Preparation

*   **Iteration ID:** `I5`
*   **Goal:** Complete comprehensive documentation (README, API docs, migration guide), create example Rails app, finalize gemspec, prepare CHANGELOG, and ensure gem is ready for v0.1.0 release.
*   **Prerequisites:** `I1`, `I2`, `I3`, `I4` (All functionality implemented and tested)
*   **Tasks:**

<!-- anchor: task-i5-t1 -->
*   **Task 5.1: Write Comprehensive README**
    *   **Task ID:** `I5.T1`
    *   **Description:** Create a comprehensive `README.md` file that serves as the primary user-facing documentation for the gem. The README must include the following sections: (1) **Introduction**: Brief description of activejob-temporal, what it does, key benefits (durable execution, fault tolerance, observability). (2) **Features**: Bulleted list of v0.1 features (enqueue, enqueue_at, retry_on/discard_on mapping, cancellation, search attributes, transactional enqueue). (3) **Installation**: How to add gem to Gemfile, `bundle install`, gemspec dependency requirements (Ruby >= 4.0, Rails >= 7.2). (4) **Quick Start**: Step-by-step guide to get started: (a) Add gem to Gemfile. (b) Configure adapter in `config/initializers/active_job.rb`: `Rails.application.config.active_job.queue_adapter = :temporal`. (c) Configure Temporal connection in `config/initializers/activejob_temporal.rb` (example configuration block with target, namespace, etc.). (d) Write a sample job (e.g., `class WelcomeEmailJob < ApplicationJob; def perform(user_id); ...; end; end`). (e) Enqueue job: `WelcomeEmailJob.perform_later(user.id)`. (f) Run worker: `bin/temporal-worker`. (5) **Configuration**: Detailed list of all configuration options (copy from `docs/configuration_reference.md`), with descriptions, types, defaults, examples. Include environment variable usage (e.g., `ENV['TEMPORAL_TARGET']`). (6) **Scheduled Jobs**: How to use `set(wait:)` for scheduled execution, example code. (7) **Retries**: How to use `retry_on` and `discard_on`, examples of retry policies, how they map to Temporal. (8) **Cancellation**: How to cancel jobs using `ActiveJob::Temporal.cancel(job_class, job_id)`, example code, note about heartbeating for prompt cancellation. (9) **Observability**: Explain Search Attributes, how to query workflows in Temporal UI, logging capabilities, optional OpenTelemetry tracing. (10) **Worker Deployment**: Brief guide on deploying workers (systemd, Docker, Kubernetes), reference `docs/worker_setup.md` for details. (11) **Limitations (v0.1)**: List what's NOT supported (Signals, Queries, Updates, child workflows, Schedules API, multi-activity orchestration). (12) **Migration from Sidekiq/Resque**: High-level guidance, reference `docs/migration_guide.md`. (13) **Contributing**: How to contribute (report issues, submit PRs), link to GitHub issues. (14) **License**: MIT or Apache 2.0. (15) **Versioning**: SemVer, link to CHANGELOG. Use clear Markdown formatting, code examples, badges (e.g., gem version, build status if CI configured). Aim for ~300-500 lines.
    *   **Agent Type Hint:** `DocumentationAgent`
    *   **Inputs:** Entire project plan (all sections), gem functionality from I1-I4, configuration reference from I1.T3, worker setup docs from I4.T1
    *   **Input Files:**
        - `docs/configuration_reference.md`
        - `docs/worker_setup.md`
        - `lib/activejob/temporal.rb` (for configuration examples)
        - `spec/fixtures/sample_jobs.rb` (for code examples)
    *   **Target Files:**
        - `README.md`
    *   **Deliverables:** Comprehensive, user-friendly README with all required sections, code examples, clear formatting
    *   **Acceptance Criteria:**
        - `README.md` exists and is ~300-500 lines
        - All required sections are present: Introduction, Features, Installation, Quick Start, Configuration, Scheduled Jobs, Retries, Cancellation, Observability, Worker Deployment, Limitations, Migration, Contributing, License, Versioning
        - Quick Start section provides complete, copy-paste-able setup instructions
        - Configuration section lists all 9 config options with descriptions, types, defaults
        - Code examples are correct and executable
        - Markdown is properly formatted and renders correctly on GitHub
        - No broken links (all referenced docs exist)
        - README passes `markdownlint` (if configured)
    *   **Dependencies:** I1.T3 (Configuration docs), I4.T1 (Worker setup docs), all functionality from I1-I4 (for accurate feature descriptions)
    *   **Parallelizable:** No (needs complete understanding of all features)

<!-- anchor: task-i5-t2 -->
*   **Task 5.2: Generate API Documentation (YARD)**
    *   **Task ID:** `I5.T2`
    *   **Description:** Add comprehensive YARD documentation comments to all public classes and methods in the gem. Use YARD tags: `@param`, `@return`, `@raise`, `@example`, `@note`, `@see`. Document at minimum: (1) `ActiveJob::Temporal` module (entrypoint, configuration). (2) `ActiveJob::Temporal::Config` class (all attributes). (3) `ActiveJob::Temporal.client` method. (4) `ActiveJob::Temporal.cancel(job_class, job_id)` method. (5) `ActiveJob::QueueAdapters::TemporalAdapter` class (enqueue, enqueue_at, enqueue_after_transaction_commit?). (6) `AjWorkflow` class (execute method). (7) `AjRunnerActivity` class (execute method). (8) `Payload`, `RetryMapper`, `SearchAttributes` modules (public methods). Generate YARD documentation using `rake yard` (add this task to Rakefile if not present). Output to `doc/` directory. Review generated HTML docs for completeness and correctness. Acceptance: YARD docs cover all public APIs, render correctly in HTML.
    *   **Agent Type Hint:** `DocumentationAgent`
    *   **Inputs:** YARD documentation best practices, all gem code from I1-I4
    *   **Input Files:**
        - `lib/activejob/temporal.rb`
        - `lib/activejob/temporal/client.rb`
        - `lib/activejob/temporal/adapter.rb`
        - `lib/activejob/temporal/workflows/aj_workflow.rb`
        - `lib/activejob/temporal/activities/aj_runner_activity.rb`
        - `lib/activejob/temporal/payload.rb`
        - `lib/activejob/temporal/retry_mapper.rb`
        - `lib/activejob/temporal/search_attributes.rb`
        - `lib/activejob/temporal/cancel.rb`
        - `Rakefile` (add yard task if not present)
    *   **Target Files:**
        - All files in `lib/activejob/temporal/**/*.rb` (updated with YARD comments)
        - `doc/` (generated YARD HTML docs)
        - `Rakefile` (updated with `yard` task if needed)
    *   **Deliverables:** Complete YARD documentation comments, generated HTML docs
    *   **Acceptance Criteria:**
        - All public classes have YARD class-level comments
        - All public methods have YARD method-level comments with `@param`, `@return`, `@example`
        - `rake yard` task exists and runs successfully
        - YARD generates HTML documentation in `doc/` directory
        - Generated docs are browsable and include all public APIs
        - No YARD warnings about undocumented methods
    *   **Dependencies:** All code from I1-I4 (need complete codebase to document)
    *   **Parallelizable:** Yes (can run in parallel with I5.T1 if codebase is stable)

<!-- anchor: task-i5-t3 -->
*   **Task 5.3: Write Migration Guide**
    *   **Task ID:** `I5.T3`
    *   **Description:** Create `docs/migration_guide.md` with high-level guidance for migrating from traditional job queues (Sidekiq, Resque, Delayed Job) to activejob-temporal. The guide should include: (1) **Why Migrate**: Benefits of Temporal (durable scheduling, built-in retries, observability). (2) **Prerequisites**: Temporal server setup, gem installation. (3) **Migration Strategy**: (a) **Dual-Write Approach**: Run both old queue and Temporal in parallel during transition. (b) **Gradual Migration**: Migrate one job queue at a time (e.g., start with "reports" queue). (c) **Testing**: Test in staging with production-like load. (4) **Code Changes**: (a) Update adapter config to `:temporal`. (b) No job code changes required (ActiveJob compatibility). (c) Configuration mapping (e.g., Sidekiq retry → retry_on). (5) **Worker Deployment**: Shut down old workers, start Temporal workers. (6) **Draining Old Queue**: Wait for in-flight jobs to finish before full cutover. (7) **Rollback Plan**: Keep old queue config ready to revert. (8) **Common Gotchas**: (a) Payload size limits (250KB vs larger limits in Redis). (b) Idempotency requirements. (c) Cancellation requires heartbeating. (9) **Testing Checklist**: Unit tests, integration tests, load tests. (10) **Resources**: Links to Temporal docs, gem README, sample apps. Aim for ~100-200 lines, practical and actionable.
    *   **Agent Type Hint:** `DocumentationAgent`
    *   **Inputs:** Migration best practices, Sidekiq/Resque architecture knowledge, Temporal migration patterns, gem features from I1-I4
    *   **Input Files:**
        - `README.md` (for cross-references)
    *   **Target Files:**
        - `docs/migration_guide.md`
    *   **Deliverables:** Practical migration guide with clear steps and gotchas
    *   **Acceptance Criteria:**
        - `docs/migration_guide.md` exists and is ~100-200 lines
        - All required sections are present: Why Migrate, Prerequisites, Migration Strategy, Code Changes, Worker Deployment, Draining, Rollback, Gotchas, Testing Checklist, Resources
        - Guide provides actionable steps (not just theory)
        - Common gotchas are clearly called out (payload size, idempotency, heartbeating)
        - Markdown is properly formatted
        - Guide is linked from README
    *   **Dependencies:** I5.T1 (README for cross-references), understanding of all gem features
    *   **Parallelizable:** Yes (can run in parallel with I5.T1, I5.T2)

<!-- anchor: task-i5-t4 -->
*   **Task 5.4: Create Example Rails App**
    *   **Task ID:** `I5.T4`
    *   **Description:** Create a minimal example Rails application in `examples/basic_rails_app/` that demonstrates activejob-temporal usage. The example app should: (1) Be a Rails 7+ app (generated with `rails new basic_rails_app --minimal --skip-active-storage --skip-action-mailer --skip-action-cable`). (2) Include the activejob-temporal gem in Gemfile (local path: `gem 'activejob-temporal', path: '../../'`). (3) Configure Temporal adapter in `config/initializers/active_job.rb`. (4) Configure Temporal connection in `config/initializers/activejob_temporal.rb` (target, namespace from env vars). (5) Include sample jobs: (a) `app/jobs/simple_job.rb` (immediate execution). (b) `app/jobs/scheduled_job.rb` (uses set(wait:)). (c) `app/jobs/retryable_job.rb` (uses retry_on). (d) `app/jobs/cancellable_job.rb` (long-running with heartbeats). (6) Include a simple controller `app/controllers/jobs_controller.rb` with actions to enqueue each job type. (7) Include routes for job enqueue endpoints. (8) Include a README (`examples/basic_rails_app/README.md`) explaining how to run the app: start Temporal test server, run Rails server, run worker, trigger jobs via curl/browser. (9) Include a Docker Compose file (`examples/basic_rails_app/docker-compose.yml`) for running Temporal server locally (optional but helpful). Ensure the example app runs successfully and demonstrates all key features.
    *   **Agent Type Hint:** `SetupAgent` + `BackendAgent`
    *   **Inputs:** Rails app generation commands, gem usage from README and tests, sample jobs from spec/fixtures
    *   **Input Files:**
        - `README.md` (for usage examples)
        - `spec/fixtures/sample_jobs.rb` (inspiration for example jobs)
    *   **Target Files:**
        - `examples/basic_rails_app/` (entire Rails app directory structure)
        - `examples/basic_rails_app/Gemfile`
        - `examples/basic_rails_app/config/initializers/active_job.rb`
        - `examples/basic_rails_app/config/initializers/activejob_temporal.rb`
        - `examples/basic_rails_app/app/jobs/*.rb` (sample jobs)
        - `examples/basic_rails_app/app/controllers/jobs_controller.rb`
        - `examples/basic_rails_app/config/routes.rb`
        - `examples/basic_rails_app/README.md`
        - `examples/basic_rails_app/docker-compose.yml` (optional)
    *   **Deliverables:** Working example Rails app demonstrating all key features
    *   **Acceptance Criteria:**
        - Example Rails app exists in `examples/basic_rails_app/`
        - `bundle install` works in example app (gem is loaded from local path)
        - Temporal adapter is configured in initializers
        - Sample jobs exist: SimpleJob, ScheduledJob, RetryableJob, CancellableJob
        - Jobs controller exists with enqueue actions
        - Routes are configured for job enqueue endpoints
        - Example app README explains setup and usage
        - Manual test: Running example app with Temporal test server, all job types can be enqueued and execute successfully
        - Docker Compose file (if included) starts Temporal server successfully
    *   **Dependencies:** I5.T1 (README for reference), all gem functionality from I1-I4
    *   **Parallelizable:** Yes (can run in parallel with I5.T2, I5.T3 if gem is feature-complete)

<!-- anchor: task-i5-t5 -->
*   **Task 5.5: Finalize Gemspec**
    *   **Task ID:** `I5.T5`
    *   **Description:** Review and finalize `activejob-temporal.gemspec` with accurate metadata and dependencies. Ensure the gemspec includes: (1) **Metadata**: name ("activejob-temporal"), version (from `lib/activejob/temporal/version.rb`, should be "0.1.0"), authors, email, homepage (GitHub repo URL if public, or placeholder), summary (one-line description), description (paragraph description), license ("MIT" or "Apache-2.0"). (2) **Dependencies**: Runtime dependencies (`temporalio >= 1.4.1`, `activejob >= 7.2`, `globalid`). Development dependencies (`rspec ~> 3.0`, `rubocop ~> 1.0`, `simplecov ~> 0.21`, `yard ~> 0.9`). (3) **Files**: Specify files to include in gem package (`lib/**/*`, `bin/temporal-worker`, `README.md`, `LICENSE`, `CHANGELOG.md`). Exclude test files and development artifacts (`spec/**/*`, `examples/**/*`, `.git*`, `coverage/`, `doc/`). (4) **Executables**: List `bin/temporal-worker` in executables. (5) **Required Ruby Version**: `>= 4.0`. Validate gemspec by running `gem build activejob-temporal.gemspec` (should succeed without errors). Install built gem locally (`gem install activejob-temporal-0.1.0.gem`) and verify it works (smoke test: `require 'activejob-temporal'` in irb).
    *   **Agent Type Hint:** `SetupAgent`
    *   **Inputs:** Gemspec best practices, project metadata, dependency versions, file lists
    *   **Input Files:**
        - `activejob-temporal.gemspec`
        - `lib/activejob/temporal/version.rb`
        - `README.md`
        - `LICENSE`
        - `CHANGELOG.md`
    *   **Target Files:**
        - `activejob-temporal.gemspec` (finalized)
    *   **Deliverables:** Complete, valid gemspec ready for gem packaging
    *   **Acceptance Criteria:**
        - Gemspec includes all required metadata (name, version, authors, summary, description, license, homepage)
        - Runtime dependencies are declared: `temporalio`, `activejob >= 7.2`, `globalid`
        - Development dependencies are declared: `rspec`, `rubocop`, `simplecov`, `yard`
        - Files list includes all necessary runtime files, excludes tests and dev artifacts
        - Executables includes `temporal-worker`
        - Required Ruby version is `>= 4.0`
        - `gem build activejob-temporal.gemspec` succeeds without errors
        - Built gem (`.gem` file) is created
        - Installing gem locally (`gem install activejob-temporal-0.1.0.gem`) succeeds
        - Requiring gem in irb (`require 'activejob-temporal'`) succeeds
    *   **Dependencies:** I1.T1 (gemspec skeleton), I5.T1 (README), all code from I1-I4
    *   **Parallelizable:** No (should be done near end when all files finalized)

<!-- anchor: task-i5-t6 -->
*   **Task 5.6: Write CHANGELOG for v0.1.0**
    *   **Task ID:** `I5.T6`
    *   **Description:** Update `CHANGELOG.md` with detailed release notes for v0.1.0. Follow Keep a Changelog format (https://keepachangelog.com/). Include the following sections for v0.1.0: (1) **[0.1.0] - 2025-10-25** (use actual release date). (2) **Added**: List all new features: ActiveJob adapter, AjWorkflow, AjRunnerActivity, enqueue/enqueue_at support, retry_on/discard_on mapping, cancellation API, Search Attributes, worker bootstrap script, configuration module, payload serialization, comprehensive logging, OpenTelemetry tracing (optional), transactional enqueue, extensive test suite, documentation (README, YARD, migration guide), example Rails app. (3) **Changed**: None (initial release). (4) **Deprecated**: None. (5) **Removed**: None. (6) **Fixed**: None (initial release). (7) **Security**: Note payload size limit (250KB) to prevent DoS. Keep entries concise and user-focused (what changed for users, not internal implementation details). Add links to GitHub compare view if public repo.
    *   **Agent Type Hint:** `DocumentationAgent`
    *   **Inputs:** Keep a Changelog format, all features implemented in I1-I5, release date
    *   **Input Files:**
        - `CHANGELOG.md`
    *   **Target Files:**
        - `CHANGELOG.md` (updated with v0.1.0 entry)
    *   **Deliverables:** Complete CHANGELOG with v0.1.0 release notes
    *   **Acceptance Criteria:**
        - `CHANGELOG.md` includes a `[0.1.0]` section with release date
        - **Added** section lists all major features (adapter, workflow, activity, enqueue, retries, cancellation, search attributes, worker, docs, tests, examples)
        - Entries are user-focused and concise
        - CHANGELOG follows Keep a Changelog format
        - Markdown is properly formatted
    *   **Dependencies:** All features from I1-I5 (need complete feature list)
    *   **Parallelizable:** Yes (can run in parallel with I5.T5)

<!-- anchor: task-i5-t7 -->
*   **Task 5.7: Run Final Quality Checks**
    *   **Task ID:** `I5.T7`
    *   **Description:** Perform final quality checks across the entire project before release. Run the following commands and ensure all pass: (1) `bundle install` (verify Gemfile.lock is up to date). (2) `rake rubocop` (zero offenses). (3) `rake spec` (all unit and integration tests pass). (4) `rake yard` (YARD docs generate without warnings). (5) `gem build activejob-temporal.gemspec` (gem builds successfully). (6) Review coverage report (>= 90% coverage). (7) Manual smoke tests: Install gem locally, run example Rails app, enqueue and execute jobs, verify worker runs, check Temporal UI for workflows. (8) Review all documentation (README, migration guide, API docs) for accuracy and completeness. (9) Check for any TODO comments or FIXMEs in code (resolve or document). (10) Verify LICENSE file is present and correct. Create a checklist in `docs/release_checklist.md` with all these items and mark as complete. Acceptance: All quality checks pass, checklist is complete.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** All project files, quality check commands, release best practices
    *   **Input Files:**
        - `Gemfile`
        - `Rakefile`
        - `activejob-temporal.gemspec`
        - `README.md`
        - `docs/migration_guide.md`
        - All code in `lib/`, `spec/`, `bin/`
    *   **Target Files:**
        - `docs/release_checklist.md` (new checklist)
        - `Gemfile.lock` (updated if needed)
        - All files (final review and fixes)
    *   **Deliverables:** Complete release checklist, all quality checks passing, gem ready for release
    *   **Acceptance Criteria:**
        - `docs/release_checklist.md` exists with all quality check items
        - `bundle install` succeeds
        - `rake rubocop` exits with status 0
        - `rake spec` exits with status 0 (all tests pass)
        - `rake yard` succeeds without warnings
        - `gem build activejob-temporal.gemspec` succeeds
        - Coverage report shows >= 90% coverage
        - Manual smoke tests with example app succeed (jobs enqueue and execute)
        - All documentation reviewed and accurate
        - No unresolved TODO/FIXME comments in code
        - LICENSE file present
        - Checklist is marked complete
    *   **Dependencies:** I5.T1, I5.T2, I5.T3, I5.T4, I5.T5, I5.T6 (all documentation and code must be finalized)
    *   **Parallelizable:** No (final verification step, must run last)

<!-- anchor: task-i5-t8 -->
*   **Task 5.8: Create GitHub Actions CI Workflow (Optional)**
    *   **Task ID:** `I5.T8`
    *   **Description:** (Optional but recommended) Create a GitHub Actions CI workflow in `.github/workflows/ci.yml` to automate testing and quality checks. The workflow should: (1) Trigger on push and pull_request events. (2) Run on Ruby 4.0. (3) Set up Ruby with specified version. (4) Install dependencies (`bundle install`). (5) Run Rubocop (`bundle exec rubocop`). (6) Run tests (`bundle exec rake spec`). (7) Upload coverage report to Codecov or similar (optional). (8) Build gem (`gem build activejob-temporal.gemspec`). Ensure workflow runs successfully on GitHub (may require manual push to test). Add CI badge to README if configured. This task is optional for v0.1 but highly recommended for open-source projects.
    *   **Agent Type Hint:** `SetupAgent`
    *   **Inputs:** GitHub Actions documentation, Ruby CI workflow examples, project structure
    *   **Input Files:**
        - `Gemfile`
        - `Rakefile`
        - `activejob-temporal.gemspec`
    *   **Target Files:**
        - `.github/workflows/ci.yml`
        - `README.md` (updated with CI badge if workflow created)
    *   **Deliverables:** Working GitHub Actions CI workflow (optional)
    *   **Acceptance Criteria:**
        - `.github/workflows/ci.yml` exists with all required jobs
        - Workflow triggers on push and pull_request
        - Workflow runs on Ruby 4.0
        - Workflow runs bundle install, rubocop, rake spec, gem build
        - Workflow uploads coverage (optional)
        - CI badge added to README (if workflow created)
        - Manual test: Pushing to GitHub triggers workflow and it succeeds
    *   **Dependencies:** I5.T7 (all quality checks must pass locally first)
    *   **Parallelizable:** Yes (optional task, can be done last or skipped)

<!-- anchor: task-i5-t9 -->
*   **Task 5.9: Tag v0.1.0 Release (Git)**
    *   **Task ID:** `I5.T9`
    *   **Description:** Create a git tag for the v0.1.0 release. Ensure all code is committed and pushed to the main branch. Create an annotated tag: `git tag -a v0.1.0 -m "Release v0.1.0 - Initial release of activejob-temporal gem"`. Push tag to remote: `git push origin v0.1.0`. If using GitHub, create a release from the tag with release notes copied from CHANGELOG.md (v0.1.0 section). Verify tag is visible on GitHub (or Git hosting platform). This marks the official v0.1.0 release in version control.
    *   **Agent Type Hint:** `SetupAgent`
    *   **Inputs:** Git tagging best practices, SemVer, CHANGELOG content
    *   **Input Files:**
        - `CHANGELOG.md`
    *   **Target Files:** None (Git operation, creates tag in repository)
    *   **Deliverables:** Git tag `v0.1.0` created and pushed to remote
    *   **Acceptance Criteria:**
        - All code is committed and pushed to main branch
        - Annotated tag `v0.1.0` created locally: `git tag -a v0.1.0 -m "Release v0.1.0 ..."`
        - Tag pushed to remote: `git push origin v0.1.0`
        - Tag is visible in `git tag -l` and on GitHub (if applicable)
        - GitHub release created from tag with CHANGELOG notes (if using GitHub)
    *   **Dependencies:** I5.T7 (all quality checks must pass), I5.T6 (CHANGELOG must be complete)
    *   **Parallelizable:** No (final release step)

<!-- anchor: task-i5-t10 -->
*   **Task 5.10: Publish Gem to RubyGems.org (Optional)**
    *   **Task ID:** `I5.T10`
    *   **Description:** (Optional) Publish the gem to RubyGems.org for public distribution. This task is optional for v0.1 and may be deferred if the gem is only for internal use or needs further validation. To publish: (1) Ensure you have a RubyGems.org account and are logged in (`gem signin`). (2) Build gem: `gem build activejob-temporal.gemspec`. (3) Push gem to RubyGems: `gem push activejob-temporal-0.1.0.gem`. (4) Verify gem is published: `gem search activejob-temporal` or visit https://rubygems.org/gems/activejob-temporal. (5) Update README with installation instructions using public gem: `gem 'activejob-temporal', '~> 0.1'`. Note: This is a one-way operation; published gems cannot be deleted, only yanked (which is discouraged). Only perform this step if gem is ready for public release.
    *   **Agent Type Hint:** `SetupAgent`
    *   **Inputs:** RubyGems publishing documentation, gem push commands
    *   **Input Files:**
        - `activejob-temporal.gemspec`
        - Built gem file (`activejob-temporal-0.1.0.gem`)
    *   **Target Files:**
        - None (publishes to external service)
        - `README.md` (updated with public gem installation if published)
    *   **Deliverables:** Gem published to RubyGems.org (optional)
    *   **Acceptance Criteria:**
        - (If publishing) Gem is successfully pushed to RubyGems.org
        - (If publishing) Gem is searchable on RubyGems: `gem search activejob-temporal`
        - (If publishing) Gem page exists: https://rubygems.org/gems/activejob-temporal
        - (If publishing) README updated with public gem installation instructions
        - (If NOT publishing) Document reason in release notes or skip this task
    *   **Dependencies:** I5.T9 (tag must be created), I5.T7 (quality checks must pass)
    *   **Parallelizable:** No (final publication step)
