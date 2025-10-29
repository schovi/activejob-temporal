# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I5.T1",
  "iteration_id": "I5",
  "iteration_goal": "Complete comprehensive documentation (README, API docs, migration guide), create example Rails app, finalize gemspec, prepare CHANGELOG, and ensure gem is ready for v0.1.0 release.",
  "description": "Create a comprehensive README.md file that serves as the primary user-facing documentation for the gem. The README must include the following sections: (1) Introduction: Brief description of activejob-temporal, what it does, key benefits (durable execution, fault tolerance, observability). (2) Features: Bulleted list of v0.1 features (enqueue, enqueue_at, retry_on/discard_on mapping, cancellation, search attributes, transactional enqueue). (3) Installation: How to add gem to Gemfile, bundle install, gemspec dependency requirements (Ruby >= 3.2, Rails >= 6.1). (4) Quick Start: Step-by-step guide to get started including configuration examples. (5) Configuration: Detailed list of all configuration options. (6) Scheduled Jobs, (7) Retries, (8) Cancellation, (9) Observability, (10) Worker Deployment, (11) Limitations (v0.1), (12) Migration from Sidekiq/Resque, (13) Contributing, (14) License, (15) Versioning. Use clear Markdown formatting, code examples, badges. Aim for ~300-500 lines.",
  "agent_type_hint": "DocumentationAgent",
  "inputs": "Entire project plan (all sections), gem functionality from I1-I4, configuration reference from I1.T3, worker setup docs from I4.T1",
  "target_files": [
    "README.md"
  ],
  "input_files": [
    "docs/configuration_reference.md",
    "docs/worker_setup.md",
    "lib/activejob/temporal.rb",
    "spec/fixtures/sample_jobs.rb"
  ],
  "deliverables": "Comprehensive, user-friendly README with all required sections, code examples, clear formatting",
  "acceptance_criteria": "README.md exists and is ~300-500 lines; All required sections are present; Quick Start section provides complete, copy-paste-able setup instructions; Configuration section lists all 9 config options with descriptions, types, defaults; Code examples are correct and executable; Markdown is properly formatted and renders correctly on GitHub; No broken links (all referenced docs exist); README passes markdownlint (if configured)",
  "dependencies": [
    "I1.T3",
    "I4.T1"
  ],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: introduction-and-goals (from 01_Context_and_Drivers.md)

**Overview of project vision, objectives, scope, and assumptions for activejob-temporal gem**

The activejob-temporal gem provides a production-ready ActiveJob adapter backed by Temporal's durable execution engine. This integration enables Rails applications to leverage Temporal's reliability, observability, and fault-tolerance capabilities with minimal code changes.

**Key Objectives:**
- Drop-in replacement for existing ActiveJob adapters (Sidekiq, Resque, etc.)
- Durable, fault-tolerant job execution backed by Temporal workflows
- Support for immediate and scheduled job execution
- Comprehensive retry configuration (retry_on/discard_on mapping)
- Job cancellation API
- Search attributes for visibility in Temporal UI
- Transactional enqueue support (defer until DB commit)

**Target Audience:**
- Rails developers seeking improved reliability for background jobs
- Teams already using Temporal who want to integrate with ActiveJob
- Organizations needing better observability and debugging for asynchronous work

### Context: project-vision (from 01_Context_and_Drivers.md)

**High-level vision for bridging ActiveJob and Temporal with minimal code changes**

The activejob-temporal gem's vision is to provide the simplest possible path for Rails applications to adopt Temporal's durable execution model. Developers should be able to replace their existing queue adapter (e.g., Sidekiq) with `:temporal` and immediately gain:

- **Durable execution:** Jobs survive process restarts and infrastructure failures
- **Built-in retries:** Leverage Temporal's battle-tested retry policies
- **Superior observability:** Use Temporal UI and search attributes to track job execution
- **Simplified operations:** No separate Redis or database-backed queue infrastructure needed

The gem achieves this by implementing the ActiveJob adapter interface and mapping job semantics (enqueue, retry_on, discard_on) to Temporal primitives (workflows, activities, retry policies).

### Context: functional-requirements-summary (from 01_Context_and_Drivers.md)

**Core functional requirements for job execution, scheduling, retries, and visibility**

The gem must provide:

1. **Job Enqueue:**
   - Support `MyJob.perform_later(args)` for immediate execution
   - Support `MyJob.set(wait: duration).perform_later(args)` for scheduled execution
   - Serialize job arguments safely (JSON, GlobalID support)

2. **Retry Behavior:**
   - Map `retry_on ExceptionClass, wait: duration, attempts: N` to Temporal RetryPolicy
   - Map `discard_on ExceptionClass` to non-retryable errors
   - Support exponential backoff and custom retry intervals

3. **Job Cancellation:**
   - Provide API to cancel in-flight jobs: `ActiveJob::Temporal.cancel(job_class, job_id)`
   - Best-effort cancellation (requires activity heartbeating for prompt termination)

4. **Observability:**
   - Attach search attributes (job class, queue, job_id, tenant_id, enqueued_at)
   - Enable filtering and debugging in Temporal UI
   - Emit structured JSON logs for integration with logging infrastructure

5. **Reliability:**
   - Support transactional enqueue (`enqueue_after_transaction_commit?`)
   - Idempotent workflow execution (deterministic workflow IDs)
   - Graceful worker shutdown

### Context: key-objectives (from 01_Context_and_Drivers.md)

**Functional and non-functional objectives including reliability, observability, and maintainability**

**Functional Objectives:**
- ✅ Drop-in ActiveJob adapter
- ✅ Immediate and scheduled job execution
- ✅ Retry/discard behavior mapping
- ✅ Job cancellation
- ✅ Search attributes for visibility
- ✅ Transactional enqueue support

**Non-Functional Objectives:**
- **Reliability:** Fault-tolerant execution, workflow durability, automatic retries
- **Performance:** Minimal adapter overhead (<10ms per enqueue), efficient serialization
- **Scalability:** Horizontal worker scaling, no single point of failure
- **Observability:** Structured logging, search attributes, OpenTelemetry tracing support
- **Maintainability:** Clean Ruby code, >= 90% test coverage, YARD documentation
- **Security:** Safe payload serialization, 250KB payload limit, TLS support
- **Usability:** Minimal learning curve, clear error messages, comprehensive documentation

### Context: scope (from 01_Context_and_Drivers.md)

**What's included in v0.1 (workflows, activities, adapter) and explicitly out of scope**

**In Scope for v0.1:**
- ActiveJob adapter implementation
- Single workflow + activity pattern (one job = one workflow + one activity)
- Immediate enqueue (`perform_later`)
- Scheduled enqueue (`set(wait:).perform_later`)
- Retry mapping (`retry_on` → RetryPolicy)
- Discard mapping (`discard_on` → non-retryable errors)
- Job cancellation API
- Search attributes (job class, queue, job_id, tenant_id, enqueued_at)
- Transactional enqueue support
- Worker bootstrap script
- Configuration DSL
- Comprehensive documentation

**Explicitly Out of Scope for v0.1:**
- Multi-activity workflows (job chains/pipelines) → v0.3
- Temporal Schedules API (recurring jobs) → v0.2
- Signals/Queries/Updates → v0.3
- Child workflows → v0.3
- Rails generators → v1.0
- ActiveRecord callback interception → deferred
- Built-in metrics/alerting → v0.2

### Context: technology-stack-summary (from 02_Architecture_Overview.md)

**Complete technology stack including Ruby, Rails, Temporal, and dependencies**

**Core Technologies:**
- **Ruby:** >= 3.2 (required for latest Temporal SDK features)
- **Rails:** >= 6.1 (ActiveJob 6.1+)
- **Temporal Ruby SDK:** >= 1.0 (temporalio gem)
- **ActiveJob:** >= 6.1 (core framework)
- **GlobalID:** >= 0.3 (for ActiveRecord model serialization)

**Development Dependencies:**
- **RSpec:** Testing framework
- **Rubocop:** Linting and style enforcement
- **SimpleCov:** Code coverage reporting (target >= 90%)
- **YARD:** API documentation generation

**Serialization:**
- JSON for workflow payloads
- ActiveJob::Arguments serializer (supports GlobalID, primitives, arrays, hashes)

**Deployment:**
- Docker / Kubernetes (optional)
- systemd / Foreman / other process managers
- Temporal cluster (self-hosted or Temporal Cloud)

**Observability:**
- Temporal Web UI (built-in)
- Structured JSON logging (semantic_logger or stdlib Logger)
- OpenTelemetry tracing (optional, via enable_tracing config)

### Context: component-diagram (from 03_System_Structure_and_Data.md)

**C4 Level 3 diagram detailing adapter and activity internal components**

The gem's internal architecture consists of the following primary components:

**1. TemporalAdapter (ActiveJob::QueueAdapters::TemporalAdapter)**
   - Implements ActiveJob adapter interface: `enqueue(job)`, `enqueue_at(job, timestamp)`
   - Calls supporting modules: Payload, RetryMapper, SearchAttributes
   - Starts Temporal workflows via Client

**2. Client (ActiveJob::Temporal::Client)**
   - Memoized Temporalio::Client singleton
   - Configured via `ActiveJob::Temporal.config`
   - Provides connection to Temporal cluster

**3. AjWorkflow (Temporal Workflow)**
   - Single workflow definition for all jobs
   - Handles scheduled execution via `Workflow.sleep`
   - Executes AjRunnerActivity with retry policy

**4. AjRunnerActivity (Temporal Activity)**
   - Deserializes job payload
   - Instantiates job class
   - Calls `job.perform(*args)`
   - Maps exceptions to retryable/non-retryable

**5. Supporting Modules:**
   - **Payload:** Serializes/deserializes job arguments
   - **RetryMapper:** Translates retry_on/discard_on to RetryPolicy
   - **SearchAttributes:** Builds search attributes hash
   - **Logger:** Structured JSON logging
   - **Cancel:** Job cancellation API

**6. Configuration (ActiveJob::Temporal::Configuration)**
   - DSL for configuring client, timeouts, retries
   - Accessed via `ActiveJob::Temporal.config`

### Context: data-entities (from 03_System_Structure_and_Data.md)

**Key data entities including job payload, search attributes, and retry policy**

**Job Payload (Workflow Input):**
```ruby
{
  job_class: "SendInvoiceJob",           # String, required
  job_id: "550e8400-e29b-41d4-a716-...", # String, required (UUID)
  queue_name: "billing",                  # String, required
  arguments: [1234, { notify: true }],    # Array, required (serialized)
  scheduled_at: "2025-10-25T14:30:00Z",  # String (ISO8601), optional
  executions: 0,                          # Integer, required
  exception_executions: {}                # Hash, required
}
```

**Search Attributes:**
```ruby
{
  ajClass: "SendInvoiceJob",             # Keyword
  ajQueue: "billing",                     # Keyword
  ajJobId: "550e8400-...",               # Keyword
  ajEnqueuedAt: Time.now,                 # Datetime
  ajTenantId: "tenant-456"                # Keyword (optional)
}
```

**Retry Policy:**
```ruby
{
  initial_interval: 30,                   # Seconds (from config or retry_on wait:)
  backoff_coefficient: 2.0,               # Float (exponential backoff)
  maximum_attempts: 1,                    # Integer (from retry_on attempts: or config)
  non_retryable_error_types: ["FatalError"] # Array of exception class names (from discard_on)
}
```

### Context: configuration-reference (from configuration_reference.md)

**Configuration options with descriptions, types, defaults, and examples**

The gem provides 10 configuration options:

1. **target** (String, default: `"127.0.0.1:7233"`) - Temporal frontend service host:port
2. **namespace** (String, default: `"default"`) - Temporal namespace for workflows
3. **task_queue_prefix** (String or nil, default: `nil`) - Optional prefix for task queue names
4. **default_activity_timeout** (Duration, default: `15.minutes`) - Activity start_to_close timeout
5. **default_retry_initial_interval** (Duration, default: `30.seconds`) - Initial retry delay
6. **default_retry_backoff** (Float, default: `2.0`) - Exponential backoff factor
7. **default_retry_max_attempts** (Integer, default: `1`) - Max retry attempts (when no retry_on)
8. **logger** (Logger, default: `Rails.logger` or `Logger.new($stdout)`) - Log destination
9. **enable_tracing** (Boolean, default: `true`) - Enable OpenTelemetry instrumentation
10. **max_payload_size_kb** (Integer, default: `250`) - Max payload size before error

**Example Configuration:**
```ruby
ActiveJob::Temporal.configure do |config|
  config.target = "temporal.example.com:7233"
  config.namespace = "production"
  config.task_queue_prefix = "rails-"
  config.default_activity_timeout = 30.seconds
  config.enable_tracing = false
end
```

### Context: worker-setup (from worker_setup.md)

**Worker bootstrap script usage and environment variables**

The gem provides a `bin/temporal-worker` executable for running workers.

**Required Environment Variables:**
- `TEMPORAL_TARGET` - Temporal server address (e.g., `localhost:7233`)
- `TEMPORAL_NAMESPACE` - Temporal namespace (e.g., `default`)
- `AJ_TEMPORAL_WORKER_QUEUE` - Task queue to poll (e.g., `default`)
- `AJ_TEMPORAL_MAX_ACT` (optional) - Max concurrent activities (default: `100`)

**Starting the Worker:**
```bash
TEMPORAL_TARGET=localhost:7233 \
TEMPORAL_NAMESPACE=default \
AJ_TEMPORAL_WORKER_QUEUE=default \
bin/temporal-worker
```

**Expected Log Output:**
```json
{"event":"worker_started","task_queue":"default","max_concurrent_activities":100,"namespace":"default","target":"localhost:7233","timestamp":"2024-05-01T18:42:13Z"}
```

**Graceful Shutdown:**
Press `Ctrl+C` or send `SIGTERM`. Worker finishes in-flight activities before exiting.

### Context: api-cancellation (from 04_Behavior_and_Communication.md)

**Job cancellation via cancel API**

The gem provides a cancellation API for stopping in-flight jobs:

```ruby
ActiveJob::Temporal.cancel(SendInvoiceJob, "550e8400-e29b-41d4-a716-446655440000")
```

**Behavior:**
- Builds deterministic workflow ID: `"ajwf:<ClassName>:<job_id>"`
- Retrieves workflow handle from Temporal
- Calls `handle.cancel`
- Best-effort: If workflow not found or already completed, logs warning but doesn't raise
- For prompt cancellation, job's `perform` method should call `Temporalio::Activity::Context.current.heartbeat` periodically

**Limitations:**
- Jobs that don't heartbeat may not terminate immediately
- Cancellation is asynchronous (workflow may still execute cleanup logic)

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `README.md`
    *   **Summary:** Currently contains a minimal placeholder README (~50 lines) with basic installation and usage instructions. Needs significant expansion to become comprehensive user documentation.
    *   **Recommendation:** You MUST replace the existing README with the comprehensive version. Keep the existing structure but expand every section significantly. Add all 15 required sections.

*   **File:** `docs/configuration_reference.md`
    *   **Summary:** Complete, well-structured configuration reference listing all 10 config options with types, defaults, descriptions, and usage examples. Also includes Search Attributes documentation.
    *   **Recommendation:** You SHOULD reuse content from this file for the Configuration section of the README. Include the configuration table and example code block. Reference this file for deeper details.

*   **File:** `docs/worker_setup.md`
    *   **Summary:** Comprehensive worker setup guide with prerequisites, environment variables, startup commands, log output examples, and manual testing instructions.
    *   **Recommendation:** You SHOULD adapt content from this file for the Worker Deployment section of the README. Include the environment variables table and startup command example. Reference this file for deployment details.

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** Main entrypoint defining the Configuration class with all config options and the `ActiveJob::Temporal.configure` DSL. Also exposes `client` and `cancel` methods.
    *   **Recommendation:** Use this file to verify the exact list of configuration options (10 options). Reference the `cancel` method signature for the Cancellation section.

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** Contains sample job classes demonstrating various features: SimpleJob, RetryableJob (with retry_on), DiscardableJob (with discard_on), LongRunningJob (with heartbeat for cancellation), TestJob, ScheduledJob, etc.
    *   **Recommendation:** You SHOULD use these job definitions as the basis for code examples in the README. For example, use RetryableJob to demonstrate retry_on usage, DiscardableJob for discard_on, and LongRunningJob for cancellation.

*   **File:** `lib/activejob/temporal/adapter.rb`
    *   **Summary:** Implements the TemporalAdapter with `enqueue`, `enqueue_at`, and `enqueue_after_transaction_commit?` methods. This is the core integration point between ActiveJob and Temporal.
    *   **Recommendation:** Reference this file to verify the adapter's capabilities (immediate enqueue, scheduled enqueue, transactional enqueue) when writing the Features section.

*   **File:** `lib/activejob/temporal/cancel.rb`
    *   **Summary:** Implements the cancellation API with the exact method signature `ActiveJob::Temporal.cancel(job_class, job_id)`. Handles workflow not found errors gracefully.
    *   **Recommendation:** Use this file to verify the cancel API signature and behavior for the Cancellation section. Include best-effort cancellation note.

*   **File:** `activejob-temporal.gemspec`
    *   **Summary:** Gem specification with metadata, dependencies, and version. Declares Ruby >= 3.2, Rails >= 6.1, and Temporal >= 1.0 as dependencies.
    *   **Recommendation:** Use this file to verify installation requirements and dependencies for the Installation section. Include Ruby and Rails version requirements.

*   **File:** `lib/activejob/temporal/version.rb`
    *   **Summary:** Defines the current version as `"0.1.0"`.
    *   **Recommendation:** Include version badge or mention in the README header.

*   **File:** `CHANGELOG.md`
    *   **Summary:** Currently contains only a placeholder entry for "Unreleased" with "Initial project setup". Needs to be updated with v0.1.0 release notes (handled in I5.T6).
    *   **Recommendation:** Reference this file for versioning information. The README should link to CHANGELOG for release history.

### Implementation Tips & Notes

*   **Tip:** The Configuration section should be a summary/table format for quick reference. You SHOULD copy the configuration table from `docs/configuration_reference.md` (lines 5-18) into the README and add a note: "For detailed configuration documentation, see [Configuration Reference](docs/configuration_reference.md)."

*   **Tip:** For the Quick Start section, provide a complete, copy-pasteable example that includes: (1) Installation (Gemfile), (2) Configuration (initializer), (3) Setting adapter, (4) Sample job definition, (5) Enqueuing the job, (6) Starting the worker. This should be runnable by someone new to the gem.

*   **Tip:** The Features section should be a bulleted list with brief descriptions. Example format:
    - ✅ **Immediate job execution:** Use `MyJob.perform_later(args)` for instant enqueue
    - ✅ **Scheduled execution:** Use `MyJob.set(wait: 5.minutes).perform_later(args)` for delayed jobs
    - ✅ **Retry mapping:** ActiveJob `retry_on` declarations automatically map to Temporal retry policies
    - ✅ **Discard mapping:** `discard_on` maps to non-retryable errors
    - ✅ **Job cancellation:** Cancel in-flight jobs via `ActiveJob::Temporal.cancel(JobClass, job_id)`
    - ✅ **Search attributes:** Filter and debug jobs in Temporal UI using job class, queue, ID, tenant
    - ✅ **Transactional enqueue:** Jobs defer enqueue until database transaction commits

*   **Tip:** The Scheduled Jobs section should show a practical example using `set(wait:)` or `set(wait_until:)`. Reference the sample_jobs.rb for inspiration. Include a note that Temporal's Schedules API (for recurring jobs) is planned for v0.2.

*   **Tip:** The Retries section should demonstrate both `retry_on` and `discard_on` with code examples from sample_jobs.rb. Include a note about exponential backoff and configurable retry policies.

*   **Tip:** The Cancellation section must include the EXACT method signature: `ActiveJob::Temporal.cancel(JobClass, job_id)`. Include a warning that jobs must heartbeat for prompt cancellation (reference LongRunningJob example).

*   **Tip:** The Observability section should explain Search Attributes and link to the configuration reference for the `tctl` registration command. Mention Temporal UI filtering capabilities.

*   **Tip:** The Worker Deployment section should include the basic worker startup command and link to `docs/worker_setup.md` for detailed deployment instructions.

*   **Tip:** The Limitations section should clearly state what's NOT in v0.1:
    - No multi-activity workflows (job chains) → v0.3
    - No recurring jobs via Temporal Schedules → v0.2
    - No Signals/Queries/Updates → v0.3
    - No ActiveRecord callback interception
    - 250KB payload size limit enforced

*   **Tip:** The Migration section should be a brief overview with a link to `docs/migration_guide.md` (which will be created in I5.T3). Include common migration steps: (1) Add gem, (2) Change adapter, (3) Configure Temporal, (4) Deploy workers, (5) Drain old queue.

*   **Tip:** The Contributing section should include: "Contributions welcome! Please open an issue or PR. Ensure tests pass (`rake spec`) and code is linted (`rake rubocop`)."

*   **Tip:** The License section should state "MIT. See [LICENSE](LICENSE)."

*   **Tip:** The Versioning section should state: "This project follows [Semantic Versioning](https://semver.org/). See [CHANGELOG](CHANGELOG.md) for release history."

*   **Note:** The task specifies ~300-500 lines. Given the 15 required sections, aim for concise but complete documentation. Use tables, code blocks, and bullet points to maximize information density without verbosity.

*   **Note:** Include a project status badge or warning at the top: "⚠️ This gem is under active development. Expect rapid iteration and potential breaking changes until v1.0.0." (This already exists in the current README - keep it.)

*   **Warning:** Ensure all code examples are syntactically correct and executable. Test them mentally against the actual implementation. For example, the cancel API takes TWO arguments (job_class, job_id), not just job_id.

*   **Warning:** Do not invent features that don't exist. Only document what has been implemented in iterations I1-I4. For example, Temporal Schedules API is NOT implemented yet (planned for v0.2), so don't document it as a current feature.

*   **Success Criterion:** The README should be comprehensive enough that a Rails developer with no prior Temporal experience can: (1) Install the gem, (2) Configure it, (3) Convert an existing job, (4) Start a worker, (5) Enqueue and execute a job successfully - all within 15-30 minutes of reading the documentation.
