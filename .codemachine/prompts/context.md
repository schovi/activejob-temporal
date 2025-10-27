# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I4.T1",
  "iteration_id": "I4",
  "iteration_goal": "Implement the Temporal worker bootstrap script, write comprehensive integration tests with a real Temporal test server, and validate end-to-end functionality (enqueue → workflow → activity → job execution).",
  "description": "Create `bin/temporal-worker` executable script that bootstraps a Temporal worker process. The script must: (1) Require the gem's entrypoint (`require 'activejob-temporal'`). (2) Require Rails environment if RAILS_ROOT env var is set (for loading job classes): `require File.expand_path('../config/environment', ENV['RAILS_ROOT'])` (or similar). (3) Read worker configuration from environment variables: `TEMPORAL_TARGET`, `TEMPORAL_NAMESPACE`, `AJ_TEMPORAL_WORKER_QUEUE` (task queue to poll), `AJ_TEMPORAL_MAX_ACT` (max concurrent activities, default 100). (4) Get Temporal client using `ActiveJob::Temporal.client` (configured via env vars or config file). (5) Create Temporal worker: `worker = Temporalio::Worker.new(client: client, task_queue: ENV.fetch('AJ_TEMPORAL_WORKER_QUEUE', 'default'), workflows: [ActiveJob::Temporal::Workflows::AjWorkflow], activities: [ActiveJob::Temporal::Activities::AjRunnerActivity], shutdown_signals: %w[SIGINT SIGTERM], max_concurrent_activity_task_executions: ENV.fetch('AJ_TEMPORAL_MAX_ACT', 100).to_i)`. (6) Start worker with `worker.run` (blocks until shutdown signal). (7) Log worker startup and shutdown events using `Logger.log_event`. (8) Handle graceful shutdown: on SIGTERM/SIGINT, worker finishes in-flight activities before exiting. Make the script executable (`chmod +x bin/temporal-worker`). Write basic manual test instructions in `docs/worker_setup.md` explaining how to run the worker locally against a Temporal test server.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Section 3.9 (Deployment View - Worker Bootstrap), temporalio Ruby worker documentation, environment variable best practices",
  "target_files": [
    "bin/temporal-worker",
    "docs/worker_setup.md"
  ],
  "input_files": [
    "lib/activejob-temporal.rb",
    "lib/activejob/temporal/workflows/aj_workflow.rb",
    "lib/activejob/temporal/activities/aj_runner_activity.rb",
    "lib/activejob/temporal/client.rb",
    "lib/activejob/temporal/logger.rb"
  ],
  "deliverables": "Executable worker script, worker setup documentation, working graceful shutdown",
  "acceptance_criteria": "`bin/temporal-worker` file exists and is executable (`chmod +x`); Script starts with shebang: `#!/usr/bin/env ruby`; Script requires gem entrypoint and (optionally) Rails environment; Worker is created with correct parameters: `task_queue`, `workflows`, `activities`, `shutdown_signals`, `max_concurrent_activity_task_executions`; Worker starts and blocks on `worker.run`; Log event \"worker_started\" is written with task_queue, max_concurrency; On SIGTERM/SIGINT, worker gracefully shuts down (logs \"worker_shutdown\" event); `docs/worker_setup.md` includes: prerequisites (Temporal test server running), how to run worker (`bin/temporal-worker`), environment variables needed, expected log output; Manual test: Running `TEMPORAL_TARGET=localhost:7233 AJ_TEMPORAL_WORKER_QUEUE=default bin/temporal-worker` starts worker without errors (can be tested manually or in integration tests)",
  "dependencies": [
    "I1.T4",
    "I1.T8",
    "I2.T2",
    "I2.T3"
  ],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: logging-strategy (from 05_Operational_Architecture.md)

```markdown
##### **Logging Strategy**

**Structured Logging (JSON Format)**

The gem emits structured logs to `Rails.logger` (configurable via `ActiveJob::Temporal.config.logger`).

**Log Events & Attributes:**

| Event | Level | Attributes | Example |
|-------|-------|------------|---------|
| **Workflow Enqueued** | `info` | `workflow_id`, `run_id`, `job_class`, `job_id`, `queue`, `scheduled_at` (optional) | `{"event": "workflow_enqueued", "workflow_id": "ajwf:SendInvoiceJob:abc123", ...}` |
| **Activity Started** | `info` | `workflow_id`, `run_id`, `activity_id`, `job_class`, `attempt` | `{"event": "activity_started", "attempt": 1, ...}` |
| **Activity Completed** | `info` | `workflow_id`, `duration_ms`, `job_class` | `{"event": "activity_completed", "duration_ms": 1234, ...}` |
| **Activity Failed** | `error` | `workflow_id`, `attempt`, `exception_class`, `exception_message`, `backtrace` (first 5 lines) | `{"event": "activity_failed", "exception_class": "PSP::TransientError", ...}` |
| **Activity Retry** | `warn` | `workflow_id`, `attempt`, `next_retry_interval`, `exception_class` | `{"event": "activity_retry", "attempt": 2, "next_retry_interval": 60, ...}` |
| **Cancellation Requested** | `warn` | `workflow_id`, `job_id`, `reason` (optional) | `{"event": "cancellation_requested", ...}` |
| **Cancellation Acknowledged** | `info` | `workflow_id`, `activity_id` | `{"event": "cancellation_acknowledged", ...}` |
| **Payload Size Warning** | `warn` | `job_class`, `payload_size_kb`, `limit_kb` | `{"event": "payload_size_warning", "payload_size_kb": 200, ...}` |
| **Serialization Error** | `error` | `job_class`, `job_id`, `exception_class`, `exception_message` | `{"event": "serialization_error", ...}` |

**Logger Configuration:**

```ruby
# config/initializers/activejob_temporal.rb
ActiveJob::Temporal.configure do |c|
  c.logger = SemanticLogger['ActiveJobTemporal'] # or Rails.logger
end
```

**Best Practices:**

- **Include Correlation IDs**: Always log `workflow_id` and `run_id` for traceability
- **Redact Sensitive Data**: Do not log job arguments directly (may contain PII); log argument count or types only
- **Use Semantic Logger**: Recommended for JSON output + tagging support
```

### Context: worker-authorization (from 05_Operational_Architecture.md)

```markdown
**Worker Authorization**

- **Task Queue Isolation**: Workers only poll queues they're configured for
  - Example: "billing" worker only processes billing jobs
  - Prevents cross-queue job execution
- **No Dynamic Queue Switching (v0.1)**: Workers are statically configured with one task queue

**Recommendation**: Use Temporal's namespace-level access control + mTLS for production deployments.
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal/workflows/aj_workflow.rb`
    *   **Summary:** This file defines the `AjWorkflow` class that orchestrates job execution. It inherits from `Temporalio::Workflow::Definition` and implements the `execute(payload)` method with sleep logic for scheduled jobs.
    *   **Recommendation:** You MUST reference this workflow class when creating the worker. Use `ActiveJob::Temporal::Workflows::AjWorkflow` in the workflows array.
    *   **Note:** The file includes a shim for `Temporalio::Workflow::Definition` that creates a dummy class when the SDK is not loaded. Your worker script should work with the REAL Temporal SDK.

*   **File:** `lib/activejob/temporal/activities/aj_runner_activity.rb`
    *   **Summary:** This file defines the `AjRunnerActivity` class that hydrates and executes ActiveJob jobs inside Temporal activities. It handles exception mapping for discard_on behavior.
    *   **Recommendation:** You MUST reference this activity class when creating the worker. Use `ActiveJob::Temporal::Activities::AjRunnerActivity` in the activities array.
    *   **Note:** Like the workflow, this file includes shims for `Temporalio::Activity::Definition` and `Temporalio::Activity::ApplicationError` for testing. The worker will use the real SDK classes.

*   **File:** `lib/activejob/temporal/client.rb`
    *   **Summary:** This module provides the `Client.build(configuration)` method that creates a `Temporalio::Client` instance with TLS support (optional, via env vars or config).
    *   **Recommendation:** You SHOULD use `ActiveJob::Temporal.client` to get the client instance for the worker. This client is already configured with the correct target, namespace, and TLS settings.
    *   **Critical Detail:** The client method will read from `ActiveJob::Temporal.config`, which itself reads from environment variables like `TEMPORAL_TARGET` and `TEMPORAL_NAMESPACE`.

*   **File:** `lib/activejob/temporal/logger.rb`
    *   **Summary:** This module provides structured JSON logging with `log_event(event_name, attributes)` and level-specific methods (`info`, `warn`, `error`). It supports both standard Ruby Logger and SemanticLogger.
    *   **Recommendation:** You MUST use `ActiveJob::Temporal::Logger.log_event("worker_started", attributes)` and `Logger.log_event("worker_shutdown", attributes)` to log worker lifecycle events.
    *   **Tip:** Include relevant attributes in your log events: `task_queue`, `max_concurrent_activities`, etc. This follows the architectural best practices for including correlation IDs and operational metadata.

*   **File:** `spec/spec_helper.rb`
    *   **Summary:** This is the RSpec test configuration file. It requires `simplecov` for coverage tracking and loads the gem with `require "activejob/temporal"`.
    *   **Recommendation:** Your worker script should follow a similar pattern: require the gem entrypoint (`require "activejob-temporal"`), then access modules via `ActiveJob::Temporal`.

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** This file defines multiple sample ActiveJob classes for testing (SimpleJob, RetryableJob, DiscardableJob, etc.). It includes a shim for `ApplicationJob` to work without Rails.
    *   **Note:** This demonstrates how jobs are defined. When the worker script requires the Rails environment (`RAILS_ROOT`), it will load real job classes from the Rails app.

### Implementation Tips & Notes

*   **Tip:** The bin/ directory currently exists but is empty. You MUST create the `bin/temporal-worker` script from scratch.

*   **Tip:** After creating the script, you MUST make it executable using `chmod +x bin/temporal-worker` (you can do this via Bash tool after writing the file).

*   **Critical Architecture Decision:** The worker configuration is read from environment variables, NOT from `ActiveJob::Temporal.config` directly. This is because:
    1. The config module reads from ENV by default (see I1.T3 implementation)
    2. Environment variables allow workers to be deployed with different settings without code changes
    3. The task spec explicitly calls out these env vars: `TEMPORAL_TARGET`, `TEMPORAL_NAMESPACE`, `AJ_TEMPORAL_WORKER_QUEUE`, `AJ_TEMPORAL_MAX_ACT`

*   **Worker Creation Pattern:** Based on the task description, the worker should be created with:
    ```ruby
    worker = Temporalio::Worker.new(
      client: client,
      task_queue: ENV.fetch('AJ_TEMPORAL_WORKER_QUEUE', 'default'),
      workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
      activities: [ActiveJob::Temporal::Activities::AjRunnerActivity],
      shutdown_signals: %w[SIGINT SIGTERM],
      max_concurrent_activity_task_executions: ENV.fetch('AJ_TEMPORAL_MAX_ACT', 100).to_i
    )
    ```

*   **Rails Environment Loading:** The script MUST conditionally require the Rails environment only if `ENV['RAILS_ROOT']` is set. This allows:
    1. The worker to run standalone for testing (without Rails)
    2. The worker to load job classes from a Rails app in production

    Pattern to use:
    ```ruby
    if ENV['RAILS_ROOT']
      require File.expand_path('../config/environment', ENV['RAILS_ROOT'])
    end
    ```

*   **Graceful Shutdown:** According to the Temporal SDK documentation, when you pass `shutdown_signals: %w[SIGINT SIGTERM]`, the worker automatically handles graceful shutdown. You do NOT need to manually trap signals - the SDK does this for you. However, you SHOULD log the shutdown event. The worker will finish in-flight activities before exiting when a shutdown signal is received.

*   **Logging Requirements:** Based on the architecture document's logging strategy, you should log:
    - `worker_started` with attributes: `task_queue`, `max_concurrent_activities`, `namespace`, `target`
    - `worker_shutdown` with attributes: `task_queue`, `reason` (e.g., "SIGTERM received")

*   **Error Handling:** If client creation fails (e.g., cannot connect to Temporal), the `ActiveJob::Temporal.client` method will raise an `ActiveJob::Temporal::Error` with a descriptive message. You SHOULD let this error propagate and crash the worker (fail-fast principle) - do not catch and retry indefinitely.

*   **Documentation File:** You MUST create `docs/worker_setup.md` with:
    1. Prerequisites: Temporal test server running (or production cluster)
    2. Environment variables needed (with examples)
    3. How to run the worker: `bin/temporal-worker`
    4. Expected log output (JSON format with worker_started event)
    5. How to stop the worker (Ctrl+C or SIGTERM)

*   **Testing Note:** This task includes manual testing instructions. Full integration tests will be written in I4.T2-I4.T8. For now, focus on making the worker script executable and well-documented.

### Project Conventions

*   **Frozen String Literals:** All Ruby files in this project start with `# frozen_string_literal: true`. Your worker script MUST include this.

*   **Module Structure:** The gem uses `ActiveJob::Temporal` as the top-level namespace. All worker-related code should reference this namespace.

*   **Configuration Access:** Always use `ActiveJob::Temporal.config` to access configuration, and `ActiveJob::Temporal.client` to get the Temporal client instance.

*   **Shebang Convention:** Executable scripts use `#!/usr/bin/env ruby` as the shebang, which makes them portable across different Ruby installations.

### Potential Pitfalls

*   **Warning:** The worker script is an EXECUTABLE, not a library file. Do NOT add it to `lib/`. It goes in `bin/`.

*   **Warning:** The worker will BLOCK on `worker.run`. This is intentional - the worker is a long-running process, not a script that exits immediately.

*   **Warning:** Environment variable defaults matter. `TEMPORAL_TARGET` and `TEMPORAL_NAMESPACE` should be read from config (which has defaults), but `AJ_TEMPORAL_WORKER_QUEUE` and `AJ_TEMPORAL_MAX_ACT` are worker-specific and should use `ENV.fetch` with inline defaults.

*   **Warning:** The Temporal SDK's `Temporalio::Worker.new` expects an array of workflow/activity CLASSES, not instances. Pass the class objects directly: `workflows: [AjWorkflow]`, not `workflows: [AjWorkflow.new]`.

---

## 4. Success Criteria Checklist

Use this checklist to verify your implementation meets all requirements:

- [ ] `bin/temporal-worker` exists and is executable (`chmod +x`)
- [ ] Script starts with `#!/usr/bin/env ruby` shebang
- [ ] Script includes `# frozen_string_literal: true` at the top
- [ ] Script requires gem entrypoint: `require "activejob-temporal"`
- [ ] Script conditionally requires Rails environment if `ENV['RAILS_ROOT']` is set
- [ ] Worker reads configuration from ENV vars: `TEMPORAL_TARGET`, `TEMPORAL_NAMESPACE`, `AJ_TEMPORAL_WORKER_QUEUE`, `AJ_TEMPORAL_MAX_ACT`
- [ ] Worker gets client via `ActiveJob::Temporal.client`
- [ ] Worker is created with correct parameters (task_queue, workflows array, activities array, shutdown_signals, max_concurrent_activity_task_executions)
- [ ] Worker starts with `worker.run`
- [ ] Log event "worker_started" is written with task_queue and max_concurrency attributes
- [ ] Worker gracefully shuts down on SIGTERM/SIGINT (handled by SDK)
- [ ] Log event "worker_shutdown" is written when shutting down
- [ ] `docs/worker_setup.md` exists with all required sections
- [ ] Documentation includes prerequisites (Temporal server running)
- [ ] Documentation includes all environment variables with examples
- [ ] Documentation includes how to run the worker
- [ ] Documentation includes expected log output examples
- [ ] Manual test: Running `TEMPORAL_TARGET=localhost:7233 AJ_TEMPORAL_WORKER_QUEUE=default bin/temporal-worker` starts worker without errors
