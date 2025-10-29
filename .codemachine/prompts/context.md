# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I5.T4",
  "iteration_id": "I5",
  "iteration_goal": "Complete comprehensive documentation (README, API docs, migration guide), create example Rails app, finalize gemspec, prepare CHANGELOG, and ensure gem is ready for v0.1.0 release.",
  "description": "Create a minimal example Rails application in examples/basic_rails_app/ that demonstrates activejob-temporal usage. The example app should: (1) Be a Rails 7+ app. (2) Include the activejob-temporal gem in Gemfile (local path). (3) Configure Temporal adapter and connection in initializers. (4) Include sample jobs: SimpleJob, ScheduledJob, RetryableJob, CancellableJob. (5) Include a simple controller with actions to enqueue each job type. (6) Include routes for job enqueue endpoints. (7) Include a README explaining how to run the app. (8) Include a Docker Compose file for running Temporal server locally (optional). Ensure the example app runs successfully and demonstrates all key features.",
  "agent_type_hint": "SetupAgent",
  "inputs": "Rails app generation commands, gem usage from README and tests, sample jobs from spec/fixtures",
  "target_files": [
    "examples/basic_rails_app/Gemfile",
    "examples/basic_rails_app/config/initializers/active_job.rb",
    "examples/basic_rails_app/config/initializers/activejob_temporal.rb",
    "examples/basic_rails_app/app/jobs/*.rb",
    "examples/basic_rails_app/app/controllers/jobs_controller.rb",
    "examples/basic_rails_app/config/routes.rb",
    "examples/basic_rails_app/README.md",
    "examples/basic_rails_app/docker-compose.yml"
  ],
  "input_files": [
    "README.md",
    "spec/fixtures/sample_jobs.rb"
  ],
  "deliverables": "Working example Rails app demonstrating all key features",
  "acceptance_criteria": "Example Rails app exists in examples/basic_rails_app/; bundle install works in example app (gem is loaded from local path); Temporal adapter is configured in initializers; Sample jobs exist: SimpleJob, ScheduledJob, RetryableJob, CancellableJob; Jobs controller exists with enqueue actions; Routes are configured for job enqueue endpoints; Example app README explains setup and usage; Manual test: Running example app with Temporal test server, all job types can be enqueued and execute successfully; Docker Compose file (if included) starts Temporal server successfully",
  "dependencies": [
    "I5.T1"
  ],
  "parallelizable": true,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: key-objectives (from 01_Context_and_Drivers.md)

```markdown
<!-- anchor: key-objectives -->
### 1.2. Key Objectives

- **Seamless Integration**: Enable Rails developers to use standard ActiveJob APIs (`perform_later`, `set(wait:)`, `retry_on`, `discard_on`) with Temporal as the execution backend
- **Durable Execution**: Guarantee job execution survives process crashes, network partitions, and infrastructure failures through Temporal's workflow persistence
- **Production-Grade Scheduling**: Support both immediate and delayed execution with millisecond precision using Temporal's native timer primitives (no polling workers)
- **Transparent Retry Semantics**: Map ActiveJob's declarative retry DSL (`retry_on`/`discard_on`) to Temporal's activity retry policies with exponential backoff
- **Idempotency & Deduplication**: Prevent duplicate job execution through deterministic workflow IDs and Temporal's conflict resolution policies
- **Operational Visibility**: Expose job metadata (class, queue, ID, timestamps) as Temporal Search Attributes for real-time monitoring and historical analysis
- **Graceful Cancellation**: Provide programmatic job cancellation with proper cleanup through Temporal's cancellation propagation
- **Rails Ecosystem Compatibility**: Support Rails 6.1+ with Ruby 3.2+ and integrate with standard Rails patterns (transactional callbacks, GlobalID serialization)
```

### Context: scope (from 01_Context_and_Drivers.md)

```markdown
<!-- anchor: scope -->
### 1.3. Scope

**In Scope for v0.1:**

- Single-workflow, single-activity execution model (`AjWorkflow` → `AjRunnerActivity`)
- ActiveJob adapter implementing `enqueue` and `enqueue_at` (immediate and scheduled execution)
- Retry policy mapping from `retry_on`/`discard_on` declarations to Temporal activity retries
- Idempotent execution through deterministic workflow IDs and `id_conflict_policy: :reject`
- Cancellation API via `ActiveJob::Temporal.cancel(job_id)`
- Search Attributes for visibility: `ajClass`, `ajQueue`, `ajJobId`, `ajEnqueuedAt`, optional `ajTenantId`
- Configuration for Temporal connection, namespace, task queues, timeouts, and retry defaults
- Worker bootstrap script for registering workflows/activities
- Logging and optional OpenTelemetry tracing integration
- Transactional enqueueing (`enqueue_after_transaction_commit`)
- Support for Rails 6.1+ and Ruby 3.2+ with the official `temporalio` gem (GA October 2025)

**Out of Scope for v0.1:**

- Temporal Update handlers (dynamic job parameter updates)
- Child workflows (nested job orchestration)
- Multi-activity workflows (complex fan-out/fan-in patterns)
- Temporal Schedules API integration (cron-like mass scheduling)
- Explicit DLQ (Dead Letter Queue) orchestration UI
- Signals/Queries for external job interaction
- Custom serializers beyond ActiveJob::Arguments (JSON + GlobalID)
- Per-job custom retry policies (only DSL-based mapping)
```

### Context: key-components (from 01_Plan_Overview_and_Setup.md)

```markdown
<!-- anchor: key-components -->
### Key Components/Services

**Primary Components:**

1. **TemporalAdapter** (`lib/activejob/temporal/adapter.rb`)
   - Implements `ActiveJob::QueueAdapters::AbstractAdapter`
   - Handles `enqueue(job)` and `enqueue_at(job, timestamp)`
   - Orchestrates payload serialization, retry mapping, search attributes
   - Starts Temporal workflows via client

2. **AjWorkflow** (`lib/activejob/temporal/workflows/aj_workflow.rb`)
   - Temporal workflow definition
   - Implements durable sleep for scheduled jobs
   - Executes AjRunnerActivity with retry policy
   - Deterministic execution (no I/O, no randomness)

3. **AjRunnerActivity** (`lib/activejob/temporal/activities/aj_runner_activity.rb`)
   - Temporal activity definition
   - Deserializes payload and instantiates ActiveJob
   - Executes job.perform(args)
   - Maps exceptions to retryable/non-retryable errors
   - Sets idempotency keys

4. **Client** (`lib/activejob/temporal/client.rb`)
   - Memoized Temporal client singleton
   - Connects to Temporal server using config
   - Used by adapter and cancellation API

**Supporting Modules:**

5. **Payload** (`lib/activejob/temporal/payload.rb`)
   - Serializes ActiveJob arguments to JSON
   - Validates payload size (<= 250KB)
   - Deserializes arguments back to Ruby objects
   - Supports GlobalID (ActiveRecord models)

6. **RetryMapper** (`lib/activejob/temporal/retry_mapper.rb`)
   - Translates retry_on/discard_on to Temporal RetryPolicy
   - Extracts retry parameters from job class metadata
   - Returns hash with initial_interval, backoff_coefficient, maximum_attempts, non_retryable_error_types

7. **SearchAttributes** (`lib/activejob/temporal/search_attributes.rb`)
   - Builds Temporal search attributes from job
   - Returns hash with ajClass, ajQueue, ajJobId, ajEnqueuedAt, optional ajTenantId
   - Enables visibility in Temporal UI

8. **Logger** (`lib/activejob/temporal/logger.rb`)
   - Structured JSON logging helper
   - Wraps Rails.logger or semantic_logger
   - Used for adapter events (enqueue, cancel, worker start/stop)

9. **Cancel** (`lib/activejob/temporal/cancel.rb`)
   - Cancellation API: `ActiveJob::Temporal.cancel(job_class, job_id)`
   - Builds workflow_id, gets handle, calls handle.cancel
   - Best-effort cancellation (requires heartbeating for prompt abort)
```

### Context: technology-stack (from 01_Plan_Overview_and_Setup.md)

```markdown
**Core Technologies:**
- **Language**: Ruby >= 3.2 (3.3+ preferred)
- **Framework**: Rails >= 6.1 (ActiveJob)
- **Orchestration Engine**: Temporal Server 1.22+
- **Temporal SDK**: `temporalio` GA (October 2025+)

**Key Dependencies:**
- `temporalio` (required) - Temporal client, workflow, activity runtime
- `activejob` via Rails (required) - Job abstraction, serialization, DSL
- `globalid` via Rails (required) - Serialize ActiveRecord models as job arguments
- `opentelemetry-sdk` (optional) - Distributed tracing spans
- `semantic_logger` (optional) - Structured logging (JSON output), falls back to `Logger`

**Serialization & Data Formats:**
- **Job Arguments**: JSON (via `ActiveJob::Arguments`)
- **Workflow Input/Output**: JSON (Temporal default)
- **Activity Input/Output**: JSON
- **Logs**: JSON (structured)

**Not Required (vs. Traditional Stacks):**
- ❌ Redis (no separate queue storage)
- ❌ PostgreSQL job tables (no `delayed_jobs` schema)
- ❌ Separate scheduler process (Temporal handles scheduling)
- ❌ Custom retry/DLQ infrastructure (Temporal provides this)
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `README.md` (lines 76-161)
    *   **Summary:** Contains complete Quick Start guide with step-by-step setup instructions
    *   **Key Content:**
        - Installation steps (Gemfile, bundle install)
        - Configuration example (initializer with all options)
        - Search attributes registration command
        - Sample job definition (SendInvoiceJob with retry_on/discard_on)
        - Enqueue examples (immediate and scheduled)
        - Worker startup command with environment variables
        - Temporal UI verification steps
    *   **Recommendation:** Use this as the blueprint for your example app. The README already provides the exact configuration and usage patterns you should demonstrate.

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** Contains comprehensive test jobs demonstrating all retry patterns
    *   **Available Jobs:**
        - `SimpleJob` - basic job with no retry logic
        - `ScheduledJob` - placeholder for scheduled execution
        - `RetryableJob` - retry_on with wait and attempts
        - `DiscardableJob` - both retry_on and discard_on
        - `TestJob` - simple job with perform method that sets class variable
        - `RetryTestJob` - transient error retry scenario (fails once, succeeds on retry)
        - `DiscardTestJob` - discard_on demonstration
        - `LongRunningJob` - demonstrates heartbeating for cancellation (10 iterations, 1 second each)
    *   **Recommendation:** You MUST reuse these job definitions (or simplified versions) in your example app. Copy the patterns from TestJob, RetryTestJob, DiscardTestJob, and LongRunningJob.

*   **File:** `docker-compose.yml` (root directory)
    *   **Summary:** Complete Temporal development stack with PostgreSQL, Temporal server, and UI
    *   **Services:**
        - `postgresql` - Database for Temporal (port 5432)
        - `temporal` - Temporal server (port 7233)
        - `temporal-ui` - Web UI (port 8080)
    *   **Content:** 60 lines, production-ready configuration with health checks
    *   **Recommendation:** You SHOULD copy this docker-compose.yml into the example app directory, or reference it in the example app README with instructions to use the root-level file.

*   **File:** `bin/temporal-worker`
    *   **Summary:** Production-ready worker bootstrap script
    *   **Key Features:**
        - Loads gem and Rails environment (if RAILS_ROOT set)
        - Configures client from environment variables (TEMPORAL_TARGET, TEMPORAL_NAMESPACE)
        - Accepts AJ_TEMPORAL_WORKER_QUEUE and AJ_TEMPORAL_MAX_ACT env vars
        - Graceful shutdown handling (SIGINT/SIGTERM)
        - Structured logging for worker lifecycle events
    *   **Recommendation:** Your example app README MUST document how to run this worker script with RAILS_ROOT pointing to the example app.

*   **File:** `docs/configuration_reference.md`
    *   **Summary:** Detailed configuration documentation with all 10 options
    *   **Includes:**
        - Complete configuration table with types, defaults, descriptions
        - Usage examples with all options
        - Search attributes explanation and registration command
        - Temporal UI query examples
    *   **Recommendation:** Link to this file from your example app README instead of duplicating the configuration documentation.

*   **File:** `lib/activejob/temporal.rb` (lines 0-80)
    *   **Summary:** Gem entrypoint with configuration DSL
    *   **Configuration attributes:**
        - `target` (String, default "127.0.0.1:7233")
        - `namespace` (String, default "default")
        - `task_queue_prefix` (String/nil, default nil)
        - `default_activity_timeout` (Duration, default 15.minutes)
        - `default_retry_initial_interval` (Duration, default 30.seconds)
        - `default_retry_backoff` (Float, default 2.0)
        - `default_retry_max_attempts` (Integer, default 1)
        - `logger` (Logger, default Rails.logger or stdout)
        - `enable_tracing` (Boolean, default true)
        - `max_payload_size_kb` (Integer, default 250)
    *   **Recommendation:** Your initializer MUST call `ActiveJob::Temporal.configure` with at least target, namespace, and queue adapter settings.

### Implementation Tips & Notes

*   **Tip: Rails App Generation:** Use `rails new examples/basic_rails_app --skip-javascript --skip-asset-pipeline --skip-test --skip-bundle --api` to create a minimal Rails 7 API-only app. This keeps the example simple and focused on background jobs.

*   **Tip: Gemfile Local Path:** In the example app's Gemfile, reference the parent gem with:
    ```ruby
    gem "activejob-temporal", path: "../.."
    ```
    This allows developers to test the gem without publishing to RubyGems.

*   **Tip: Docker Compose Reuse:** Instead of duplicating the docker-compose.yml, you can:
    1. Copy the root docker-compose.yml into examples/basic_rails_app/
    2. OR instruct users in the README to run `docker-compose up` from the project root
    Option 2 is simpler and avoids duplication.

*   **Tip: Search Attributes Setup:** Your example app README MUST include the search attributes registration command from docs/configuration_reference.md. Users need to run this BEFORE starting the worker, or workflows will fail to start.

*   **Tip: Job Controller Actions:** Create simple controller actions that enqueue jobs and return JSON responses. Example:
    ```ruby
    # POST /jobs/simple
    def simple
      SimpleJob.perform_later("Hello from API")
      render json: { status: "enqueued", job: "SimpleJob" }
    end

    # POST /jobs/scheduled
    def scheduled
      ScheduledJob.set(wait: 30.seconds).perform_later("Scheduled message")
      render json: { status: "scheduled", delay: "30 seconds" }
    end
    ```

*   **Tip: Routes Pattern:** Use a namespace for job-related endpoints:
    ```ruby
    namespace :jobs do
      post :simple
      post :scheduled
      post :retryable
      post :cancellable
      delete :cancel, to: 'jobs#cancel'
    end
    ```

*   **Note: Rails 7 Defaults:** Rails 7 requires Ruby 2.7+, but the gem requires Ruby 3.2+. Your example app should target Ruby 3.2+ in .ruby-version and document this in the README.

*   **Note: ActiveJob Adapter Configuration:** The initializer MUST set the queue adapter BEFORE configuring Temporal:
    ```ruby
    # config/initializers/active_job.rb
    Rails.application.config.active_job.queue_adapter = :temporal
    ```
    AND you need a separate Temporal configuration initializer:
    ```ruby
    # config/initializers/activejob_temporal.rb
    ActiveJob::Temporal.configure do |config|
      config.target = ENV.fetch("TEMPORAL_TARGET", "127.0.0.1:7233")
      config.namespace = ENV.fetch("TEMPORAL_NAMESPACE", "default")
    end
    ```

*   **Warning: Job Class Inheritance:** Your example jobs MUST inherit from `ApplicationJob` (or `ActiveJob::Base`), NOT the custom ApplicationJob stub in spec/fixtures/sample_jobs.rb. Use standard Rails job generation or create ApplicationJob in app/jobs/.

*   **Warning: Worker RAILS_ROOT:** When running the worker for the example app, users MUST set `RAILS_ROOT` environment variable pointing to the example app directory. Your README should include a complete worker startup command like:
    ```bash
    RAILS_ROOT=/path/to/examples/basic_rails_app \
    TEMPORAL_TARGET=localhost:7233 \
    TEMPORAL_NAMESPACE=default \
    AJ_TEMPORAL_WORKER_QUEUE=default \
    bin/temporal-worker
    ```
    (Adjust bin/temporal-worker path to ../../bin/temporal-worker from example app root)

*   **Warning: Heartbeat for Cancellation:** The LongRunningJob pattern from sample_jobs.rb demonstrates proper cancellation with heartbeating:
    ```ruby
    def perform
      10.times do
        Temporalio::Activity::Context.current.heartbeat
        sleep 1
        # Do work
      end
    end
    ```
    Your CancellableJob MUST follow this pattern, or cancellation will only take effect after the job completes (not during execution).

### Required Example App Structure

Based on task requirements, you MUST create these files:

```
examples/basic_rails_app/
├── Gemfile                                   # Rails 7 + local activejob-temporal gem
├── Gemfile.lock                              # Generated by bundle install
├── README.md                                 # Setup and usage instructions
├── Rakefile                                  # Standard Rails tasks
├── config.ru                                 # Rack config
├── bin/
│   ├── rails
│   └── setup
├── config/
│   ├── application.rb
│   ├── boot.rb
│   ├── environment.rb
│   ├── routes.rb                             # Job enqueue routes
│   ├── database.yml                          # SQLite for simplicity
│   ├── environments/
│   │   └── development.rb
│   └── initializers/
│       ├── active_job.rb                     # Set queue_adapter = :temporal
│       └── activejob_temporal.rb             # Configure Temporal connection
├── app/
│   ├── jobs/
│   │   ├── application_job.rb                # Base job class
│   │   ├── simple_job.rb                     # Basic job
│   │   ├── scheduled_job.rb                  # Delayed execution demo
│   │   ├── retryable_job.rb                  # retry_on demo
│   │   └── cancellable_job.rb                # Heartbeat + cancellation demo
│   └── controllers/
│       └── jobs_controller.rb                # Enqueue actions for each job type
├── db/
│   └── schema.rb                             # Minimal schema (if needed)
└── docker-compose.yml (optional)             # Or reference root docker-compose.yml
```

### Acceptance Criteria Checklist

Use this to verify your implementation:

- [ ] `rails new` command creates Rails 7+ app in examples/basic_rails_app/
- [ ] Gemfile includes `gem "activejob-temporal", path: "../.."`
- [ ] `bundle install` succeeds without errors
- [ ] config/initializers/active_job.rb sets `queue_adapter = :temporal`
- [ ] config/initializers/activejob_temporal.rb configures Temporal (target, namespace)
- [ ] Four jobs exist: SimpleJob, ScheduledJob, RetryableJob, CancellableJob
- [ ] Jobs inherit from ApplicationJob (standard Rails pattern)
- [ ] RetryableJob has `retry_on` declaration
- [ ] CancellableJob has heartbeat calls in perform method
- [ ] JobsController exists with actions: simple, scheduled, retryable, cancellable, cancel
- [ ] Routes are configured (namespace :jobs or similar)
- [ ] README.md exists with:
  - [ ] Prerequisites (Ruby 3.2+, Docker for Temporal)
  - [ ] Setup steps (bundle install, docker-compose up, search attributes registration)
  - [ ] Worker startup command (with RAILS_ROOT, env vars)
  - [ ] How to enqueue jobs (curl examples or rails console)
  - [ ] How to verify in Temporal UI
- [ ] Docker Compose file (copied or referenced) starts Temporal successfully
- [ ] Manual test: Start Temporal, start worker, enqueue job, verify execution

### Next Steps Recommendation

1. **Generate Rails app:** Run `rails new examples/basic_rails_app --skip-javascript --skip-asset-pipeline --skip-test --skip-bundle --api` from project root
2. **Set up Gemfile:** Add local gem reference `gem "activejob-temporal", path: "../.."`
3. **Create initializers:** Two separate files for ActiveJob adapter and Temporal config
4. **Define jobs:** Copy patterns from spec/fixtures/sample_jobs.rb, adapt to Rails ApplicationJob
5. **Create controller:** Simple actions that enqueue jobs and return JSON
6. **Configure routes:** Namespace for job endpoints
7. **Write README:** Comprehensive setup guide with all commands
8. **Test manually:** Verify complete workflow (docker-compose → worker → enqueue → execution → UI)
9. **Optional:** Copy docker-compose.yml or add clear instructions to use root file

---

## Summary

This task requires creating a minimal but complete Rails 7 example application that demonstrates all key features of the activejob-temporal gem. The example should be self-contained, easy to run (docker-compose + worker script + rails server), and serve as a reference implementation for new users.

**Key success factors:**
- Use existing patterns from README Quick Start and sample_jobs.rb
- Keep it simple (API-only Rails, minimal dependencies)
- Comprehensive README with copy-paste commands
- All four job types demonstrate distinct features (simple, scheduled, retry, cancellation)
- Complete workflow from enqueue → worker → Temporal UI is documented and testable

**Recommended action:** Follow the Next Steps and use the acceptance criteria checklist to ensure nothing is missed. Reference the root docker-compose.yml instead of duplicating it to keep the example DRY.
