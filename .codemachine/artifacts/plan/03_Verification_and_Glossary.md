# Project Plan: activejob-temporal Gem - Verification & Glossary

---

<!-- anchor: verification-and-integration-strategy -->
## 5. Verification and Integration Strategy

<!-- anchor: testing-levels -->
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
  - **Scheduled Job Execution**: Enqueue with `set(wait:)` → Workflow sleeps → Activity executes after delay
  - **Retry Behavior**: Job fails with retryable exception → Temporal retries activity per policy → Eventual success
  - **Discard Behavior**: Job fails with non-retryable exception → Workflow fails immediately without retry
  - **Cancellation**: Enqueue → Job starts → Cancel called → Activity aborts via heartbeat → Workflow cancelled
  - **Search Attributes**: Enqueue → Workflow completes → Query Temporal for attributes → Verify presence and values
- **Tools**: RSpec 3.x, Temporal test server helper, SimpleCov

**Manual Testing**

- **Scope**: Worker deployment, example Rails app, real Temporal cluster interaction
- **Location**: `examples/basic_rails_app/`, manual worker runs
- **Key Scenarios**:
  - Start Temporal test server (local)
  - Run worker process with `bin/temporal-worker`
  - Enqueue jobs from Rails console or example app
  - Verify jobs execute successfully
  - Inspect Temporal UI for workflows, history, search attributes
  - Test cancellation from Rails console
  - Test scheduled jobs (wait for execution)
- **Documentation**: `docs/worker_setup.md`, example app README

**Smoke Testing**

- **Scope**: Gem installation and basic usage
- **Key Checks**:
  - `bundle install` succeeds
  - `require 'activejob-temporal'` succeeds in irb
  - Adapter can be configured: `Rails.application.config.active_job.queue_adapter = :temporal`
  - Gem builds successfully: `gem build activejob-temporal.gemspec`
  - Built gem installs locally: `gem install activejob-temporal-0.1.0.gem`

---

<!-- anchor: ci-cd-strategy -->
### 5.2. CI/CD Strategy

**Continuous Integration (GitHub Actions)**

- **Trigger**: On push to main branch, pull requests
- **Ruby Versions**: Test on Ruby 3.2 and 3.3 (matrix)
- **Jobs**:
  1. **Lint**: Run Rubocop (`bundle exec rubocop`), fail build on offenses
  2. **Unit Tests**: Run RSpec unit tests (`bundle exec rake spec:unit`), fail on test failures
  3. **Integration Tests**: Run RSpec integration tests with Temporal test server (`bundle exec rake spec:integration`), fail on test failures
  4. **Coverage Check**: Upload coverage report to Codecov (optional), enforce >= 90% threshold
  5. **YARD Docs**: Generate YARD docs (`bundle exec rake yard`), fail on warnings
  6. **Gem Build**: Build gem (`gem build activejob-temporal.gemspec`), fail if build errors
- **Artifacts**: Coverage reports, built gem file
- **Badge**: Add CI status badge to README

**Continuous Deployment (Optional for v0.1)**

- **v0.1**: Manual gem release (tag → build → push to RubyGems)
- **v0.2+**: Automate release on tag creation (GitHub Actions workflow: detect tag, build gem, push to RubyGems)

**Pre-Commit Hooks (Optional)**

- **Recommended Tools**: Overcommit or Husky for Ruby
- **Hooks**:
  - Run Rubocop on staged files (auto-correct if possible)
  - Run affected unit tests (optional, may be slow)
- **Goal**: Catch issues before CI

---

<!-- anchor: code-quality-gates -->
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
- **Coverage**: Aim for 100% documentation coverage of public API

**Dependency Security Scanning**

- **Tool**: `bundler-audit` (scan for vulnerable dependencies)
- **Frequency**: Run in CI on each push
- **Action**: Fail build if high-severity vulnerabilities detected
- **Command**: `bundle exec bundler-audit check --update`

**Payload Size Validation**

- **Enforcement**: Raise `ActiveJob::SerializationError` if payload > 250KB
- **Testing**: Unit tests verify size limit enforcement
- **Logging**: Warn at 100KB (before hard limit)

**Non-Determinism Checks (Workflow)**

- **Manual Review**: Code reviews must verify workflow code contains no I/O, randomness, or direct system time calls
- **Allowed Operations**: `Workflow.now`, `Workflow.sleep`, `Workflow.execute_activity`
- **Testing**: Replay workflow history in tests to catch non-determinism (Temporal SDK feature)

---

<!-- anchor: artifact-validation -->
### 5.4. Artifact Validation

**Diagram Validation**

- **PlantUML Diagrams**: Render diagrams using PlantUML CLI or online editor (https://www.plantuml.com/plantuml/uml/)
  - **Pass Criteria**: No syntax errors, diagrams render correctly, all components/relationships are visible
- **Mermaid Diagrams**: Render diagrams using Mermaid live editor (https://mermaid.live)
  - **Pass Criteria**: No syntax errors, ERD displays all entities and relationships

**JSON Schema Validation**

- **Payload Schema**: Validate `api/job_payload_schema.json` against JSON Schema Draft 07 meta-schema
  - **Tool**: `json-schema` gem or online validator
  - **Pass Criteria**: Schema is valid, includes all required fields (job_class, job_id, queue_name, arguments)

**Markdown Linting**

- **Tool**: `markdownlint` (optional but recommended)
- **Files**: `README.md`, `CHANGELOG.md`, `docs/*.md`
- **Pass Criteria**: No markdown syntax errors, consistent formatting
- **CI Integration**: Run `markdownlint *.md docs/*.md` in CI

**Gemspec Validation**

- **Build Test**: `gem build activejob-temporal.gemspec` must succeed without errors or warnings
- **Installation Test**: Install built gem locally and require it in irb: `require 'activejob-temporal'`
- **Metadata Check**: Verify all required fields are present (name, version, authors, summary, license, etc.)

---

<!-- anchor: integration-strategy -->
### 5.5. Integration Strategy

**Component Integration Order**

The gem is built in iterative layers, with each iteration integrating new components:

1. **Iteration 1**: Foundation modules (Config, Client, Payload, RetryMapper, SearchAttributes, Logger) integrate with each other
   - **Integration Point**: Configuration feeds into all other modules
   - **Validation**: Unit tests verify module interactions (e.g., Client uses Config settings)

2. **Iteration 2**: Workflow and Activity integrate with foundation modules
   - **Integration Point**: Workflow calls Activity, Activity uses Payload and RetryMapper
   - **Validation**: Unit tests mock activity execution and verify workflow logic

3. **Iteration 3**: Adapter integrates all components for enqueue flow
   - **Integration Point**: Adapter orchestrates Payload → RetryMapper → SearchAttributes → Client → Workflow start
   - **Validation**: Unit tests mock Temporal client and verify enqueue orchestration

4. **Iteration 4**: Worker integrates Temporal SDK, Workflow, Activity for end-to-end execution
   - **Integration Point**: Worker polls Temporal → Executes Workflow → Executes Activity → Runs job
   - **Validation**: Integration tests with real Temporal test server verify full flow

5. **Iteration 5**: Documentation and examples integrate all functionality
   - **Integration Point**: README, example app, and migration guide demonstrate complete usage
   - **Validation**: Manual testing with example app, all documented features work

**External System Integration**

- **Temporal Cluster**: Gem integrates with Temporal server via gRPC
  - **Development**: Local Temporal test server (in-memory or Docker)
  - **Production**: Temporal Cloud or self-hosted cluster
  - **Validation**: Integration tests verify gRPC communication (enqueue, workflow start, activity execution, cancellation)

- **Rails Application**: Gem integrates with Rails via ActiveJob adapter interface
  - **Validation**: Adapter conforms to `ActiveJob::QueueAdapters::AbstractAdapter` contract
  - **Testing**: Example Rails app verifies integration (enqueue jobs, workers execute)

**Dependency Management**

- **temporalio-sdk**: Core dependency, tightly coupled
  - **Version Pinning**: Lock to `~> 1.0` (or appropriate GA version)
  - **Testing**: Integration tests verify SDK usage (workflow, activity, client APIs)
- **activejob**: Interface dependency, loosely coupled
  - **Version Requirement**: `>= 6.1` (support Rails 6.1+)
  - **Testing**: Unit tests verify adapter interface compliance
- **globalid**: Used for job argument serialization
  - **Version Requirement**: Provided by Rails
  - **Testing**: Payload unit tests verify GlobalID serialization

---

<!-- anchor: release-criteria -->
### 5.6. Release Criteria (v0.1.0 Go/No-Go)

**Functional Requirements (MUST PASS)**

- ✅ `perform_later` starts a Temporal workflow with expected IDs/metadata
- ✅ `set(wait:)` delays execution using Workflow.sleep (no worker thread blocked)
- ✅ `retry_on`/`discard_on` are honored (activity retries and non-retryable mapping)
- ✅ Duplicate enqueue (same job_id) is rejected (no duplicate workflows)
- ✅ `ActiveJob::Temporal.cancel(job_class, job_id)` cancels a running workflow
- ✅ Search attributes (`ajClass`, `ajQueue`, `ajJobId`, `ajEnqueuedAt`) are persisted
- ✅ Works on Ruby 3.2+ and Rails 6.1+ with temporalio/sdk-ruby GA

**Quality Requirements (MUST PASS)**

- ✅ All unit tests pass (`rake spec:unit` exits with status 0)
- ✅ All integration tests pass (`rake spec:integration` exits with status 0)
- ✅ Code coverage >= 90% (SimpleCov report)
- ✅ Zero Rubocop offenses (`rake rubocop` exits with status 0)
- ✅ YARD docs generate without warnings (`rake yard` exits with status 0)
- ✅ Gem builds successfully (`gem build activejob-temporal.gemspec` succeeds)
- ✅ Example Rails app runs and demonstrates all features

**Documentation Requirements (MUST PASS)**

- ✅ README is comprehensive (installation, quickstart, configuration, usage, limitations)
- ✅ API documentation (YARD) covers all public classes and methods
- ✅ Migration guide is complete (Sidekiq/Resque → Temporal)
- ✅ CHANGELOG includes v0.1.0 release notes
- ✅ Worker setup guide is documented

**Security Requirements (MUST PASS)**

- ✅ Payload size limit enforced (250KB max)
- ✅ Safe serialization (only ActiveJob::Arguments-compatible types)
- ✅ No secrets in logs or payloads
- ✅ TLS support for Temporal connections (documented, not enforced)

**Performance Requirements (SHOULD PASS, NOT BLOCKING)**

- ⚠️ Enqueue latency < 100ms (median, on local Temporal)
- ⚠️ Activity execution overhead < 50ms (excluding job logic)
- ⚠️ Worker can handle >= 100 concurrent activities
- Note: Performance is validated manually in I4; not a hard release blocker for v0.1

**Known Limitations (Documented, ACCEPTABLE for v0.1)**

- No Temporal Signals, Queries, or Updates
- No child workflows or multi-activity orchestration
- No Temporal Schedules API (recurring jobs)
- No custom DLQ UI
- No workflow versioning (all workers must run same gem version)
- Cancellation requires manual heartbeating in job code (not automatic)

**Release Checklist (docs/release_checklist.md)**

All items in release checklist (I5.T7) must be marked complete before release.

---

<!-- anchor: glossary -->
## 6. Glossary

**Activity**: A Temporal unit of work that performs side effects (e.g., database writes, API calls). In activejob-temporal, `AjRunnerActivity` executes the job's `perform` method. Activities are retryable and can be scheduled across multiple workers.

**ActiveJob**: Rails' abstraction layer for background job processing. Provides a unified API (`perform_later`, `retry_on`, `discard_on`) that works with multiple queue adapters (Sidekiq, Resque, and now Temporal via this gem).

**Adapter**: In the ActiveJob context, a class that implements the queue backend interface. `TemporalAdapter` translates ActiveJob's `enqueue`/`enqueue_at` methods into Temporal workflow starts.

**Adapter Pattern**: A design pattern that translates one interface to another. Here, `TemporalAdapter` translates ActiveJob's interface to Temporal's workflow API.

**ApplicationError**: A Temporal exception type that indicates an activity failed. If `non_retryable: true`, the activity will not be retried. Used to map ActiveJob's `discard_on` exceptions.

**C4 Model**: A hierarchical diagramming framework (Context, Container, Component, Code) for software architecture. Used in this plan for architecture diagrams.

**Determinism**: Property of workflow code where replaying the same inputs produces the same outputs and side effects. Required by Temporal for workflow history replay. Workflows must not use I/O, randomness, or direct system time calls; only `Workflow.now`, `Workflow.sleep`, `Workflow.execute_activity`.

**Deterministic Workflow ID**: A workflow ID that is derived from job attributes (class name + job_id) rather than randomly generated. Enables deduplication (same job_id → same workflow_id → Temporal rejects duplicate starts via `:reject` conflict policy).

**Durable Execution**: Temporal's core capability: workflows and activities survive process crashes, network failures, and restarts. State is persisted in Temporal's history database, allowing execution to resume from where it left off.

**GlobalID**: Rails feature that serializes ActiveRecord models as URIs (e.g., `gid://app/User/123`). Allows safe job argument serialization (pass model IDs, not full objects) and automatic deserialization back to models.

**gRPC**: A high-performance RPC framework used by Temporal for client-server communication. Temporal clients (this gem) communicate with the Temporal cluster via gRPC over HTTP/2.

**Heartbeat**: Periodic signal sent from an activity to Temporal indicating the activity is still alive and making progress. Enables Temporal to detect crashed activities and allows activities to receive cancellation signals promptly.

**History**: Temporal's event log for a workflow execution. Stores all decisions (timers, activity starts, results, failures) as immutable events. Used for workflow replay, debugging, and observability. Each workflow has a unique history, persisted in Temporal's database.

**Idempotency**: Property where executing an operation multiple times produces the same result as executing it once. Critical for retryable jobs. This gem provides idempotency keys (`Thread.current[:aj_temporal_idempotency_key]`) for application code to use in external API calls (e.g., HTTP `Idempotency-Key` header).

**Idempotency Key**: A unique identifier (string) provided to activity code that can be used to ensure external operations (API calls, database writes) are idempotent. Format: `"#{workflow_id}/runner"`.

**Long Polling**: Technique where workers hold open HTTP connections to Temporal, waiting for tasks. More efficient than frequent short polls. Temporal uses long polling (up to 60s timeout) for task distribution.

**Memoization**: Caching pattern where a function's result is stored and reused on subsequent calls with the same inputs. This gem memoizes the Temporal client (created once per process) to avoid repeated connection overhead.

**Namespace**: Temporal's logical isolation boundary. Workflows in different namespaces cannot interact. Recommended to use separate namespaces per environment (dev, staging, production).

**Non-Determinism**: Violation of determinism in workflow code (e.g., using `Time.now` instead of `Workflow.now`, making HTTP calls). Causes `Temporalio::Workflow::NondeterminismError` when Temporal replays workflow history with new code.

**Orchestration**: Coordination of multiple activities or workflows to achieve a business goal. Temporal's core purpose is durable orchestration (workflows orchestrate activities).

**Payload**: Serialized data passed to workflows and activities. In this gem, payloads are JSON-serialized hashes containing job class, arguments, metadata. Payload size is limited to 250KB to respect Temporal's history limits.

**PlantUML**: A text-based diagramming tool that generates UML diagrams from plain text descriptions. Used in this plan for architecture diagrams (component, container, sequence).

**RetryPolicy**: Temporal configuration defining how activities are retried on failure. Includes `initial_interval` (first retry delay), `backoff_coefficient` (exponential backoff factor), `maximum_attempts` (max retries), `non_retryable_error_types` (exceptions that should not be retried).

**RubyGems**: The Ruby package manager. Gems are distributed via RubyGems.org. This gem will be published to RubyGems for installation via `gem install activejob-temporal` or `Bundler`.

**Search Attributes**: Indexed metadata attached to workflows, enabling filtering and querying in Temporal UI. This gem attaches `ajClass` (job class), `ajQueue` (queue name), `ajJobId` (ActiveJob job_id), `ajEnqueuedAt` (timestamp), `ajTenantId` (optional tenant ID).

**SemVer**: Semantic Versioning (https://semver.org/). Version format: MAJOR.MINOR.PATCH (e.g., 0.1.0). Breaking changes increment MAJOR, new features increment MINOR, bug fixes increment PATCH.

**Signal**: Asynchronous message sent to a running workflow to trigger state changes or side effects. Not used in v0.1 (planned for v0.3).

**Task Queue**: Named queue where Temporal places workflow/activity tasks. Workers poll specific task queues for tasks. This gem maps ActiveJob queue names to Temporal task queues (with optional prefix).

**Temporal**: Open-source durable execution platform for orchestrating distributed applications. Provides workflows, activities, timers, retries, cancellation, and observability. This gem integrates Rails ActiveJob with Temporal.

**Temporal Cloud**: Managed Temporal service (SaaS) with SLA guarantees, eliminating the need to self-host Temporal clusters.

**Temporal SDK**: Client library for interacting with Temporal. This gem uses `temporalio/sdk-ruby` (official Ruby SDK, GA October 2025+) for workflows, activities, and client operations.

**Temporal Test Server**: In-memory or Docker-based Temporal server for testing. Provides full Temporal functionality without requiring a production cluster. Used in integration tests.

**Temporal UI**: Web-based user interface for Temporal. Allows viewing, querying, and debugging workflows. Accessible at Temporal server's HTTP port (default 8233 for local dev server).

**Temporal Worker**: Process that polls Temporal task queues and executes workflow/activity code. This gem provides `bin/temporal-worker` script to bootstrap workers. Workers are stateless and horizontally scalable.

**Transactional Enqueue**: Rails feature (6.1+) where `enqueue_after_transaction_commit? => true` tells ActiveJob to defer job enqueue until after database transaction commits. Prevents jobs from being enqueued for rolled-back transactions. This gem supports this by returning `true` from adapter method.

**Workflow**: Deterministic function that coordinates activities, timers, and child workflows. In activejob-temporal, `AjWorkflow` orchestrates job execution (optionally sleeps for scheduled jobs, then executes `AjRunnerActivity`). Workflows are durable and resumable after failures.

**Workflow Execution**: A single run of a workflow. Identified by `workflow_id` and `run_id`. Each execution has its own history. If a workflow is retried, it gets a new `run_id` but same `workflow_id`.

**Workflow History**: See **History**.

**Workflow ID**: Unique identifier for a workflow execution. In this gem, format is `ajwf:<JobClass>:<job_id>` (e.g., `ajwf:SendInvoiceJob:abc-123-def-456`). Enables deduplication and easy correlation with ActiveJob jobs.

**Workflow Versioning**: Temporal feature for safely deploying new workflow code while old workflows are still running. Uses `Workflow.patch` or separate workflow classes. Not implemented in v0.1 (planned for v0.2+).

**YARD**: Documentation tool for Ruby. Generates API documentation from code comments using special tags (`@param`, `@return`, `@example`, etc.). This gem uses YARD for API docs.
