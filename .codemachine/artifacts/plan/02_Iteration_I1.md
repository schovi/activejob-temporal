# Project Plan: activejob-temporal Gem - Iteration 1

---

<!-- anchor: iteration-1-plan -->
### Iteration 1: Project Setup & Core Foundation

*   **Iteration ID:** `I1`
*   **Goal:** Establish project structure, dependencies, and foundational modules (configuration, client, payload handling). Generate core architecture diagrams.
*   **Prerequisites:** None (initial iteration)
*   **Tasks:**

<!-- anchor: task-i1-t1 -->
*   **Task 1.1: Initialize Gem Structure**
    *   **Task ID:** `I1.T1`
    *   **Description:** Create the Ruby gem skeleton with standard files and directory structure as defined in Section 3 (Directory Structure). Initialize git repository, create gemspec file with metadata (name, version, authors, dependencies), create basic Gemfile for development dependencies (rspec, rubocop, simplecov, yard, temporalio-sdk, rails). Generate initial files: `lib/activejob/temporal.rb` (entrypoint), `lib/activejob/temporal/version.rb` (version constant "0.1.0"), `lib/activejob-temporal.rb` (require entrypoint), `Rakefile` (with spec, rubocop, yard tasks), `README.md` (placeholder), `CHANGELOG.md` (placeholder), `LICENSE` (MIT), `.gitignore` (standard Ruby patterns), `.rspec` (RSpec config), `.rubocop.yml` (Rubocop config with sensible defaults).
    *   **Agent Type Hint:** `SetupAgent`
    *   **Inputs:** Section 3 (Directory Structure), Ruby gem best practices, project requirements
    *   **Input Files:** []
    *   **Target Files:**
        - `activejob-temporal.gemspec`
        - `Gemfile`
        - `Gemfile.lock` (generated)
        - `Rakefile`
        - `lib/activejob/temporal.rb`
        - `lib/activejob/temporal/version.rb`
        - `lib/activejob-temporal.rb`
        - `README.md`
        - `CHANGELOG.md`
        - `LICENSE`
        - `.gitignore`
        - `.rspec`
        - `.rubocop.yml`
        - `spec/spec_helper.rb`
    *   **Deliverables:** Fully initialized gem structure with all standard files, runnable `bundle install`, passing `rake rubocop` (no code yet, just config), passing `rake spec` (no specs yet, just setup)
    *   **Acceptance Criteria:**
        - `bundle install` completes successfully without errors
        - `rake rubocop` runs without errors (even if no Ruby files to check yet)
        - `rake spec` runs without errors (no specs yet, but RSpec loads)
        - All files listed in "Target Files" exist with valid content
        - `.gitignore` includes standard patterns (`*.gem`, `Gemfile.lock`, `.bundle/`, `coverage/`, `.yardoc/`)
        - Gemspec declares dependencies: `temporalio-sdk`, `activejob` (>= 6.1), `globalid`
        - Gemspec declares development dependencies: `rspec`, `rubocop`, `simplecov`, `yard`
    *   **Dependencies:** None
    *   **Parallelizable:** No (first task, establishes foundation)

<!-- anchor: task-i1-t2 -->
*   **Task 1.2: Generate Architecture Diagrams**
    *   **Task ID:** `I1.T2`
    *   **Description:** Create PlantUML and Mermaid diagram source files for core architecture visualizations. Generate the following diagrams based on Section 2 (Core Architecture) and Section 3.6 (Data Model Overview): (1) Component Diagram (PlantUML, C4 style) showing Adapter, Workflow, Activity, Client, supporting modules and their interactions - save to `docs/diagrams/component_overview.puml`. (2) Container Diagram (PlantUML, C4 style) showing gem's internal containers and interactions with Rails, Temporal, Workers - save to `docs/diagrams/container_diagram.puml`. (3) Data Model ERD (Mermaid) showing logical relationships between Temporal entities (Workflow, Input, Activity, Search Attributes) - save to `docs/diagrams/data_model_erd.mmd`. Ensure diagrams use C4-PlantUML library for PlantUML files and standard Mermaid ER syntax for ERD. Diagrams must render without syntax errors.
    *   **Agent Type Hint:** `DocumentationAgent`
    *   **Inputs:** Section 2 (Core Architecture), Section 2.1 (Key Architectural Artifacts), Section 3.6 (Data Model Overview), C4-PlantUML library documentation, Mermaid ER diagram syntax
    *   **Input Files:** []
    *   **Target Files:**
        - `docs/diagrams/component_overview.puml`
        - `docs/diagrams/container_diagram.puml`
        - `docs/diagrams/data_model_erd.mmd`
    *   **Deliverables:** Three diagram files in correct formats (PlantUML `.puml`, Mermaid `.mmd`), accurately reflecting architecture described in plan
    *   **Acceptance Criteria:**
        - All three diagram files exist in `docs/diagrams/`
        - PlantUML files (`component_overview.puml`, `container_diagram.puml`) include `!include https://raw.githubusercontent.com/plantuml-stdlib/C4-PlantUML/master/C4_Container.puml` or equivalent C4 import
        - PlantUML files render without syntax errors when processed by PlantUML CLI/server
        - Mermaid file (`data_model_erd.mmd`) uses valid Mermaid ER diagram syntax
        - Mermaid file renders correctly in Mermaid live editor (https://mermaid.live)
        - Component diagram shows at minimum: TemporalAdapter, AjWorkflow, AjRunnerActivity, Client, Payload, RetryMapper, SearchAttributes modules
        - Container diagram shows at minimum: Rails App, Gem (with internal containers), Temporal Cluster, Worker Process
        - ERD shows entities: Workflow, WorkflowInput, Activity, SearchAttributes with relationships
    *   **Dependencies:** I1.T1 (directory structure must exist)
    *   **Parallelizable:** Yes (can run in parallel with I1.T3 if I1.T1 is complete)

<!-- anchor: task-i1-t3 -->
*   **Task 1.3: Implement Configuration Module**
    *   **Task ID:** `I1.T3`
    *   **Description:** Create the `ActiveJob::Temporal` configuration module in `lib/activejob/temporal.rb` with a configuration DSL. Implement a `Config` class with attributes: `target` (default: "127.0.0.1:7233"), `namespace` (default: "default"), `task_queue_prefix` (default: nil), `default_activity_timeout` (default: 15.minutes), `default_retry_initial_interval` (default: 30.seconds), `default_retry_backoff` (default: 2.0), `default_retry_max_attempts` (default: 1), `logger` (default: Rails.logger if Rails defined, else Logger.new(STDOUT)), `enable_tracing` (default: true). Provide `ActiveJob::Temporal.configure { |config| ... }` block method and `ActiveJob::Temporal.config` accessor (memoized singleton). Write unit tests in `spec/unit/configuration_spec.rb` covering: default values, configuration block usage, accessor methods, validation (e.g., timeout must be positive). Document configuration options in `docs/configuration_reference.md` with descriptions, types, defaults, and examples.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 2 (Core Architecture), Section 3.6 (Data Model Overview - Configuration Settings), Ruby configuration DSL patterns
    *   **Input Files:**
        - `lib/activejob/temporal.rb`
    *   **Target Files:**
        - `lib/activejob/temporal.rb` (updated with Config class and configure method)
        - `spec/unit/configuration_spec.rb`
        - `docs/configuration_reference.md`
    *   **Deliverables:** Working configuration module, passing unit tests (100% coverage for config module), comprehensive configuration reference documentation
    *   **Acceptance Criteria:**
        - `ActiveJob::Temporal.configure { |c| c.target = "localhost:7233" }` sets configuration
        - `ActiveJob::Temporal.config.target` returns configured value
        - Default values are applied when configuration block not called
        - All configuration attributes are readable and writable
        - Unit tests cover all configuration attributes and edge cases (nil values, invalid types)
        - `rake spec` passes for configuration_spec.rb
        - `docs/configuration_reference.md` lists all 9 configuration options with descriptions, types, defaults, and usage examples
        - Documentation is in Markdown format and passes `markdownlint` (if linter configured)
    *   **Dependencies:** I1.T1 (gem structure must exist)
    *   **Parallelizable:** Yes (can run in parallel with I1.T2 if I1.T1 is complete)

<!-- anchor: task-i1-t4 -->
*   **Task 1.4: Implement Temporal Client Wrapper**
    *   **Task ID:** `I1.T4`
    *   **Description:** Create `lib/activejob/temporal/client.rb` with a memoized Temporal client singleton. Implement `ActiveJob::Temporal.client` method that creates a `Temporalio::Client` connection using configuration settings (`target`, `namespace`). Support optional TLS configuration (read from env vars or config if present, but not required for v0.1 - document as optional). Ensure client is created once per process (memoized in class variable). Handle connection errors gracefully (raise descriptive error if Temporal unreachable). Write unit tests in `spec/unit/client_spec.rb` covering: client creation, memoization (second call returns same instance), configuration usage, error handling (mock unreachable Temporal server). Note: Unit tests should mock `Temporalio::Client.connect` to avoid requiring real Temporal server.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 2 (Core Architecture), temporalio-sdk Ruby documentation (Client.connect API), configuration from I1.T3
    *   **Input Files:**
        - `lib/activejob/temporal.rb`
    *   **Target Files:**
        - `lib/activejob/temporal/client.rb`
        - `spec/unit/client_spec.rb`
    *   **Deliverables:** Working Temporal client wrapper, passing unit tests (100% coverage for client module), proper error handling
    *   **Acceptance Criteria:**
        - `ActiveJob::Temporal.client` returns a `Temporalio::Client` instance (or mock in tests)
        - Calling `ActiveJob::Temporal.client` twice returns the same instance (memoization works)
        - Client uses `config.target` and `config.namespace` from configuration module
        - If `Temporalio::Client.connect` fails (mocked connection error), a descriptive error is raised
        - Unit tests use mocking/stubbing to avoid real Temporal connections
        - `rake spec` passes for client_spec.rb
        - Code passes `rake rubocop` without offenses
    *   **Dependencies:** I1.T3 (configuration module must exist)
    *   **Parallelizable:** No (depends on I1.T3 for configuration)

<!-- anchor: task-i1-t5 -->
*   **Task 1.5: Implement Payload Serializer**
    *   **Task ID:** `I1.T5`
    *   **Description:** Create `lib/activejob/temporal/payload.rb` with methods for serializing and deserializing ActiveJob arguments. Implement `Payload.from_job(job, scheduled_at: nil)` method that extracts job class name, job_id, queue_name, arguments (using ActiveJob::Arguments.serialize), scheduled_at timestamp (ISO8601 format if present), executions, and exception_executions. Return a hash suitable for JSON serialization. Implement `Payload.deserialize_args(payload)` method that converts the arguments array back to Ruby objects (using ActiveJob::Arguments.deserialize). Enforce 250KB payload size limit: raise `ActiveJob::SerializationError` if JSON-serialized payload exceeds 250KB (configurable via `config.max_payload_size_kb`, default 250). Write unit tests in `spec/unit/payload_spec.rb` covering: round-trip serialization (job → payload → args), GlobalID support (ActiveRecord models), payload size limit enforcement, error handling for non-serializable objects. Create JSON Schema for payload structure in `api/job_payload_schema.json` (Draft 07) defining required fields (job_class, job_id, queue_name, arguments) and optional fields (scheduled_at, executions, exception_executions).
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 2 (Core Architecture - Data Model Overview), Section 3.6 (Job Payload structure), ActiveJob::Arguments documentation, JSON Schema Draft 07 specification
    *   **Input Files:** []
    *   **Target Files:**
        - `lib/activejob/temporal/payload.rb`
        - `spec/unit/payload_spec.rb`
        - `api/job_payload_schema.json`
        - `spec/fixtures/sample_jobs.rb` (create sample ActiveJob jobs for testing)
    *   **Deliverables:** Working payload serializer/deserializer, passing unit tests (100% coverage), JSON Schema for payload validation, sample jobs for testing
    *   **Acceptance Criteria:**
        - `Payload.from_job(job)` returns a hash with keys: `job_class`, `job_id`, `queue_name`, `arguments`, `executions`, `exception_executions`
        - `Payload.from_job(job, scheduled_at: timestamp)` includes `scheduled_at` in ISO8601 format
        - `Payload.deserialize_args(payload)` correctly converts arguments back to Ruby objects
        - Round-trip test: `Payload.deserialize_args(Payload.from_job(job))` returns original arguments
        - GlobalID test: Passing an ActiveRecord model as argument serializes to GlobalID string and deserializes back to model (requires stubbing/mocking AR model in tests)
        - Payload size limit: Serializing a job with >250KB arguments raises `ActiveJob::SerializationError` with descriptive message
        - Non-serializable objects (e.g., Proc, Thread) raise `ActiveJob::SerializationError`
        - `api/job_payload_schema.json` validates against JSON Schema Draft 07 meta-schema
        - JSON Schema includes all required and optional fields with correct types (string, integer, array, object)
        - `rake spec` passes for payload_spec.rb
        - Code passes `rake rubocop`
    *   **Dependencies:** I1.T1 (gem structure must exist)
    *   **Parallelizable:** Yes (can run in parallel with I1.T3, I1.T4 if I1.T1 is complete)

<!-- anchor: task-i1-t6 -->
*   **Task 1.6: Implement Retry Mapper**
    *   **Task ID:** `I1.T6`
    *   **Description:** Create `lib/activejob/temporal/retry_mapper.rb` with logic to translate ActiveJob's `retry_on` and `discard_on` declarations to Temporal's `RetryPolicy` hash. Implement `RetryMapper.for(job_class)` method that inspects the job class's metadata (ActiveJob stores retry_on/discard_on in class-level instance variables or similar - research ActiveJob internals), extracts retry parameters (wait, attempts, exceptions), and returns a hash with keys: `initial_interval` (from `retry_on wait:` or config default), `backoff_coefficient` (config default 2.0), `maximum_attempts` (from `retry_on attempts:` or config default 1), `non_retryable_error_types` (array of exception class names from `discard_on`). Implement `RetryMapper.discard_exception?(job_class, exception)` method that returns true if the exception or its ancestors match any `discard_on` declarations. Handle multiple `retry_on` declarations: use the first matching exception by ancestry order. Write unit tests in `spec/unit/retry_mapper_spec.rb` covering: default retry policy (no retry_on/discard_on), single retry_on with wait and attempts, multiple retry_on declarations (precedence), discard_on mapping to non_retryable_error_types, discard_exception? method with exception hierarchies. Create sample jobs with various retry configurations in `spec/fixtures/sample_jobs.rb`.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 2 (Core Architecture - Retry Policy), Section 3.6 (Retry Policy structure), ActiveJob retry DSL documentation (retry_on/discard_on internals), configuration from I1.T3
    *   **Input Files:**
        - `lib/activejob/temporal.rb`
    *   **Target Files:**
        - `lib/activejob/temporal/retry_mapper.rb`
        - `spec/unit/retry_mapper_spec.rb`
        - `spec/fixtures/sample_jobs.rb` (updated with retry configurations)
    *   **Deliverables:** Working retry mapper, passing unit tests (100% coverage for retry mapper module), sample jobs with diverse retry configurations
    *   **Acceptance Criteria:**
        - `RetryMapper.for(SimpleJob)` returns default retry policy if no retry_on/discard_on declared
        - Default retry policy hash: `{initial_interval: 30, backoff_coefficient: 2.0, maximum_attempts: 1, non_retryable_error_types: []}`
        - `RetryMapper.for(RetryableJob)` with `retry_on SomeError, wait: 60, attempts: 5` returns `{initial_interval: 60, ..., maximum_attempts: 5, ...}`
        - `RetryMapper.for(DiscardableJob)` with `discard_on FatalError` returns `{..., non_retryable_error_types: ["FatalError"]}`
        - `RetryMapper.discard_exception?(DiscardableJob, FatalError.new)` returns true
        - `RetryMapper.discard_exception?(DiscardableJob, StandardError.new)` returns false (if FatalError not ancestor of StandardError)
        - Multiple retry_on: First matching exception by ancestry determines policy
        - Unit tests cover edge cases: exception inheritance, no retry_on but has discard_on, etc.
        - `rake spec` passes for retry_mapper_spec.rb
        - Code passes `rake rubocop`
    *   **Dependencies:** I1.T3 (configuration module must exist)
    *   **Parallelizable:** Yes (can run in parallel with I1.T4, I1.T5 if I1.T1 and I1.T3 are complete)

<!-- anchor: task-i1-t7 -->
*   **Task 1.7: Implement Search Attributes Builder**
    *   **Task ID:** `I1.T7`
    *   **Description:** Create `lib/activejob/temporal/search_attributes.rb` with a method to build Temporal Search Attributes from an ActiveJob instance. Implement `SearchAttributes.for(job)` method that returns a hash with keys: `ajClass` (job class name string), `ajQueue` (job.queue_name string), `ajJobId` (job.job_id string), `ajEnqueuedAt` (Time.now in DateTime format for Temporal), `ajTenantId` (optional, extract from job arguments if present - e.g., if first argument responds to :tenant_id, use it; otherwise nil). Search Attributes must match Temporal's type requirements: Keywords are strings, Datetime is Time object. Write unit tests in `spec/unit/search_attributes_spec.rb` covering: basic attributes (ajClass, ajQueue, ajJobId, ajEnqueuedAt), tenant_id extraction (if job has tenant_id argument), nil tenant_id (if no tenant context). Document Search Attributes in `docs/configuration_reference.md` (add a new section explaining what Search Attributes are attached and how to query them in Temporal UI).
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 2 (Core Architecture - Workflow Metadata), Section 3.6 (Workflow Metadata structure), Temporal Search Attributes documentation
    *   **Input Files:**
        - `docs/configuration_reference.md`
    *   **Target Files:**
        - `lib/activejob/temporal/search_attributes.rb`
        - `spec/unit/search_attributes_spec.rb`
        - `docs/configuration_reference.md` (updated with Search Attributes section)
    *   **Deliverables:** Working search attributes builder, passing unit tests (100% coverage), updated configuration documentation
    *   **Acceptance Criteria:**
        - `SearchAttributes.for(job)` returns a hash with at minimum: `{ajClass: "SendInvoiceJob", ajQueue: "billing", ajJobId: "uuid-123", ajEnqueuedAt: Time.now}`
        - `ajEnqueuedAt` is a Time object (Temporal Datetime type)
        - If job has a tenant context (e.g., first argument responds to :tenant_id), `ajTenantId` is included: `{..., ajTenantId: "tenant-456"}`
        - If no tenant context, `ajTenantId` is either omitted or nil (check Temporal SDK behavior)
        - Unit tests cover all scenarios: basic job, job with tenant, job without tenant
        - `docs/configuration_reference.md` includes a new section "Search Attributes" explaining: purpose, list of attributes (ajClass, ajQueue, ajJobId, ajEnqueuedAt, ajTenantId), how to query in Temporal UI, and requirement to pre-register attributes in Temporal cluster (`tctl admin cluster add-search-attributes` command example)
        - `rake spec` passes for search_attributes_spec.rb
        - Code passes `rake rubocop`
    *   **Dependencies:** I1.T1 (gem structure must exist)
    *   **Parallelizable:** Yes (can run in parallel with I1.T4, I1.T5, I1.T6 if I1.T1 is complete)

<!-- anchor: task-i1-t8 -->
*   **Task 1.8: Implement Logger Helper**
    *   **Task ID:** `I1.T8`
    *   **Description:** Create `lib/activejob/temporal/logger.rb` with a structured logging helper. Implement `Logger.log_event(event_name, attributes = {})` method that writes JSON-formatted logs to `ActiveJob::Temporal.config.logger`. Include standard attributes in every log: `event` (event_name), `timestamp` (ISO8601), plus any custom attributes passed. Support log levels: `info`, `warn`, `error`. If `semantic_logger` gem is available, use it; otherwise fall back to standard Ruby Logger with manual JSON formatting. Write unit tests in `spec/unit/logger_spec.rb` covering: log output format (JSON), standard attributes presence, custom attributes, different log levels. This is a helper module used by other components, so extensive testing is not required (basic coverage is sufficient).
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 3.8.2 (Logging Strategy), semantic_logger gem documentation (optional), Ruby Logger documentation
    *   **Input Files:**
        - `lib/activejob/temporal.rb`
    *   **Target Files:**
        - `lib/activejob/temporal/logger.rb`
        - `spec/unit/logger_spec.rb`
    *   **Deliverables:** Working logger helper, passing unit tests (basic coverage), support for JSON-formatted logs
    *   **Acceptance Criteria:**
        - `Logger.log_event("workflow_enqueued", {workflow_id: "abc123"})` writes a JSON log line to configured logger
        - Log includes: `{"event": "workflow_enqueued", "timestamp": "2025-10-25T12:00:00Z", "workflow_id": "abc123"}`
        - Supports log levels: `Logger.info(event, attrs)`, `Logger.warn(event, attrs)`, `Logger.error(event, attrs)`
        - If `semantic_logger` is available (detected via `defined?(SemanticLogger)`), use it; otherwise use stdlib Logger
        - Unit tests verify JSON structure and attribute presence (use StringIO or similar to capture log output)
        - `rake spec` passes for logger_spec.rb
        - Code passes `rake rubocop`
    *   **Dependencies:** I1.T3 (configuration module must exist for logger reference)
    *   **Parallelizable:** Yes (can run in parallel with other I1 tasks if I1.T1 and I1.T3 are complete)

<!-- anchor: task-i1-t9 -->
*   **Task 1.9: Run Rubocop and Fix Style Issues**
    *   **Task ID:** `I1.T9`
    *   **Description:** Run `rake rubocop` on all code written in Iteration 1. Fix any Rubocop offenses (style violations, complexity warnings, etc.) in all lib/ and spec/ files. Ensure code adheres to Ruby style guide. If necessary, update `.rubocop.yml` with reasonable exceptions (e.g., increase max line length to 120 if needed, disable specific cops with justification in comments). Commit fixes. Acceptance: `rake rubocop` passes with zero offenses.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Rubocop configuration (`.rubocop.yml`), Ruby style guide, code from I1.T3-I1.T8
    *   **Input Files:**
        - `lib/activejob/temporal.rb`
        - `lib/activejob/temporal/client.rb`
        - `lib/activejob/temporal/payload.rb`
        - `lib/activejob/temporal/retry_mapper.rb`
        - `lib/activejob/temporal/search_attributes.rb`
        - `lib/activejob/temporal/logger.rb`
        - `spec/unit/*.rb`
        - `.rubocop.yml`
    *   **Target Files:** All Ruby files in `lib/` and `spec/` (updated with style fixes)
    *   **Deliverables:** Clean code passing Rubocop checks
    *   **Acceptance Criteria:**
        - `rake rubocop` exits with status 0 (zero offenses)
        - All auto-correctable offenses are fixed
        - Any manual fixes are applied (e.g., method complexity reduced, long lines broken)
        - If `.rubocop.yml` is updated, changes are documented with comments explaining exceptions
    *   **Dependencies:** I1.T3, I1.T4, I1.T5, I1.T6, I1.T7, I1.T8 (all code must be written)
    *   **Parallelizable:** No (must run after all code is written)

<!-- anchor: task-i1-t10 -->
*   **Task 1.10: Run All Unit Tests and Verify Coverage**
    *   **Task ID:** `I1.T10`
    *   **Description:** Run `rake spec` to execute all unit tests written in Iteration 1. Verify that SimpleCov reports >= 90% code coverage for all modules created in this iteration (Configuration, Client, Payload, RetryMapper, SearchAttributes, Logger). If coverage is below 90%, write additional tests to cover edge cases and error paths. Generate coverage report in `coverage/index.html`. Acceptance: All tests pass, coverage >= 90%.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** RSpec configuration, SimpleCov configuration, unit tests from I1.T3-I1.T8
    *   **Input Files:**
        - `spec/spec_helper.rb`
        - `spec/unit/*.rb`
    *   **Target Files:** None (verification task, generates coverage report)
    *   **Deliverables:** Passing test suite, coverage report >= 90%
    *   **Acceptance Criteria:**
        - `rake spec` exits with status 0 (all tests pass)
        - SimpleCov report shows >= 90% coverage for `lib/activejob/temporal/*.rb` files
        - Coverage report is generated in `coverage/index.html`
        - No skipped or pending tests (all tests must be implemented)
    *   **Dependencies:** I1.T3, I1.T4, I1.T5, I1.T6, I1.T7, I1.T8 (all unit tests must be written)
    *   **Parallelizable:** No (must run after all tests are written)
