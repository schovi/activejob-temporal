# Project Plan: activejob-temporal Gem - Iteration 2

---

<!-- anchor: iteration-2-plan -->
### Iteration 2: Temporal Workflow & Activity Implementation

*   **Iteration ID:** `I2`
*   **Goal:** Implement the core Temporal workflow (`AjWorkflow`) and activity (`AjRunnerActivity`) that orchestrate and execute ActiveJob jobs. Generate sequence diagrams for execution flows.
*   **Prerequisites:** `I1` (Foundation modules must be complete: Configuration, Client, Payload, RetryMapper, SearchAttributes)
*   **Tasks:**

<!-- anchor: task-i2-t1 -->
*   **Task 2.1: Generate Sequence Diagrams for Execution Flows**
    *   **Task ID:** `I2.T1`
    *   **Description:** Create PlantUML sequence diagrams illustrating the detailed execution flows described in Section 3.7 (API Design & Communication). Generate three sequence diagrams: (1) **Job Enqueue Flow** (`docs/diagrams/enqueue_sequence.puml`) - showing the flow from Rails `perform_later` call → ActiveJob → TemporalAdapter → Payload serialization → Retry mapping → Search attributes → Temporal Client → Temporal Cluster workflow start. Include both immediate enqueue and scheduled enqueue (`set(wait:)`) variations. (2) **Workflow & Activity Execution Flow** (`docs/diagrams/execution_sequence.puml`) - showing Worker polling → AjWorkflow.execute → Workflow.sleep (if scheduled) → execute_activity → AjRunnerActivity.execute → Payload deserialization → Job instantiation → job.perform → External API call → Activity completion → Workflow completion. (3) **Cancellation Flow** (`docs/diagrams/cancellation_sequence.puml`) - showing Rails `cancel(job_id)` → Cancellation API → Workflow handle retrieval → handle.cancel → Temporal signal → Worker receives cancellation → Activity heartbeat → Cancellation acknowledged. Use standard PlantUML sequence diagram syntax with participants for each component. Diagrams must render without errors and accurately reflect the flows described in the plan.
    *   **Agent Type Hint:** `DocumentationAgent`
    *   **Inputs:** Section 3.7 (Key Interaction Flows: Enqueue, Execution, Cancellation), PlantUML sequence diagram syntax
    *   **Input Files:** []
    *   **Target Files:**
        - `docs/diagrams/enqueue_sequence.puml`
        - `docs/diagrams/execution_sequence.puml`
        - `docs/diagrams/cancellation_sequence.puml`
    *   **Deliverables:** Three PlantUML sequence diagram files accurately depicting execution flows
    *   **Acceptance Criteria:**
        - All three diagram files exist in `docs/diagrams/`
        - Diagrams use PlantUML sequence diagram syntax (`participant`, `->`, `-->`, `activate`, `deactivate`, `alt`, `note`)
        - Diagrams render without syntax errors in PlantUML processor
        - **Enqueue sequence diagram** shows: Developer → Rails App → ActiveJob → TemporalAdapter → Payload → RetryMapper → SearchAttributes → Client → Temporal Cluster, with workflow_id and task_queue resolution steps
        - **Execution sequence diagram** shows: Temporal → Worker → AjWorkflow → Temporal (sleep if scheduled) → execute_activity → Worker → AjRunnerActivity → Payload deserialization → Job class → External API → Activity complete → Workflow complete
        - **Cancellation sequence diagram** shows: Developer → Rails → CancelAPI → Client → Temporal → Worker → Activity (heartbeat) → Cancellation error → Activity cancelled
        - Diagrams include notes explaining key concepts (e.g., "Worker thread not blocked during sleep", "Idempotency key set here")
    *   **Dependencies:** None (can start immediately in I2, but conceptually relies on understanding from I1)
    *   **Parallelizable:** Yes (can run in parallel with I2.T2 if needed)

<!-- anchor: task-i2-t2 -->
*   **Task 2.2: Implement AjWorkflow (Temporal Workflow)**
    *   **Task ID:** `I2.T2`
    *   **Description:** Create `lib/activejob/temporal/workflows/aj_workflow.rb` with the Temporal workflow class `AjWorkflow`. The workflow must inherit from `Temporalio::Workflow::Definition` (or use Temporal Ruby SDK's workflow DSL). Implement `execute(payload)` method with the following logic: (1) Extract `scheduled_at` from payload. (2) If `scheduled_at` is present and in the future (compare to `Temporalio::Workflow.now`), call `Temporalio::Workflow.sleep(duration)` where duration = scheduled_at - now. This sleep is durable and non-blocking. (3) After sleep (or immediately if no scheduled_at), call `Temporalio::Workflow.execute_activity(AjRunnerActivity, payload, start_to_close_timeout: config.default_activity_timeout, retry: retry_policy)`. The retry_policy is extracted from payload metadata (or passed separately - design choice). (4) Return activity result (or void). Ensure workflow code is deterministic: no I/O, no randomness, no system time calls (use Workflow.now only). Write unit tests in `spec/unit/workflows/aj_workflow_spec.rb` using Temporal's workflow testing framework (if available in Ruby SDK) or mocking. Tests should cover: immediate execution (no sleep), scheduled execution (sleep called with correct duration), activity invocation with correct parameters. Note: Full integration tests will be in Iteration 4; this is unit-level testing only.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 3.7 (Workflow & Activity Execution Flow), temporalio Ruby workflow documentation, payload structure from I1.T5, configuration from I1.T3
    *   **Input Files:**
        - `lib/activejob/temporal.rb`
        - `lib/activejob/temporal/payload.rb`
    *   **Target Files:**
        - `lib/activejob/temporal/workflows/aj_workflow.rb`
        - `spec/unit/workflows/aj_workflow_spec.rb`
    *   **Deliverables:** Working `AjWorkflow` class, passing unit tests covering workflow logic
    *   **Acceptance Criteria:**
        - `AjWorkflow` class exists and inherits from `Temporalio::Workflow::Definition` (or equivalent)
        - `execute(payload)` method is defined
        - If `payload['scheduled_at']` is present and future, `Workflow.sleep` is called with correct duration (scheduled_at - Workflow.now)
        - If `payload['scheduled_at']` is nil or past, no sleep is called
        - After sleep (or immediately), `Workflow.execute_activity(AjRunnerActivity, payload, ...)` is called
        - Activity timeout is set to `config.default_activity_timeout`
        - Workflow code contains no I/O, randomness, or direct system time calls (only `Workflow.now`, `Workflow.sleep`, `Workflow.execute_activity`)
        - Unit tests verify sleep behavior (mock `Workflow.sleep` and assert it's called with expected duration)
        - Unit tests verify activity execution (mock `Workflow.execute_activity` and assert correct parameters)
        - `rake spec` passes for aj_workflow_spec.rb
        - Code passes `rake rubocop`
    *   **Dependencies:** I1.T3 (Configuration), I1.T5 (Payload structure)
    *   **Parallelizable:** Yes (can run in parallel with I2.T3 if I1 is complete)

<!-- anchor: task-i2-t3 -->
*   **Task 2.3: Implement AjRunnerActivity (Temporal Activity)**
    *   **Task ID:** `I2.T3`
    *   **Description:** Create `lib/activejob/temporal/activities/aj_runner_activity.rb` with the Temporal activity class `AjRunnerActivity`. The activity must inherit from `Temporalio::Activity::Definition` (or use SDK's activity DSL). Implement `execute(payload)` method with the following logic: (1) Deserialize job arguments using `Payload.deserialize_args(payload)`. (2) Extract `job_class` from payload and constantize it (`payload['job_class'].constantize`). (3) Set idempotency key in thread-local storage: `Thread.current[:aj_temporal_idempotency_key] = "#{Temporalio::Activity.info.workflow_id}/runner"`. (4) Instantiate job: `job = job_class.new`. (5) Call `job.perform(*args)`. (6) Clear idempotency key: `Thread.current[:aj_temporal_idempotency_key] = nil` (in ensure block). (7) Handle exceptions: If exception is raised, check if it matches `discard_on` using `RetryMapper.discard_exception?(job_class, exception)`. If yes, re-raise as `Temporalio::Activity::ApplicationError.new(message, non_retryable: true, cause: exception)`. Otherwise, re-raise original exception (will be retried per RetryPolicy). Write unit tests in `spec/unit/activities/aj_runner_activity_spec.rb` covering: successful execution, exception handling (retryable vs non-retryable), idempotency key lifecycle, job instantiation and perform call. Use mocking/stubbing for job classes to avoid needing real jobs in unit tests.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 3.7 (Workflow & Activity Execution Flow), Section 3.7 (Error Handling), temporalio Ruby activity documentation, Payload module from I1.T5, RetryMapper from I1.T6
    *   **Input Files:**
        - `lib/activejob/temporal/payload.rb`
        - `lib/activejob/temporal/retry_mapper.rb`
    *   **Target Files:**
        - `lib/activejob/temporal/activities/aj_runner_activity.rb`
        - `spec/unit/activities/aj_runner_activity_spec.rb`
    *   **Deliverables:** Working `AjRunnerActivity` class, passing unit tests covering activity logic and error handling
    *   **Acceptance Criteria:**
        - `AjRunnerActivity` class exists and inherits from `Temporalio::Activity::Definition` (or equivalent)
        - `execute(payload)` method is defined
        - `Payload.deserialize_args(payload)` is called to extract job arguments
        - Job class is constantized from `payload['job_class']`
        - Idempotency key is set before job execution: `Thread.current[:aj_temporal_idempotency_key]` contains workflow_id + "/runner"
        - Job is instantiated and `perform(*args)` is called
        - Idempotency key is cleared in ensure block (even if exception raised)
        - If job raises exception matching `discard_on`, it's re-raised as `ApplicationError(non_retryable: true)`
        - If job raises other exception, it's re-raised as-is (retryable)
        - Unit tests verify: successful execution, idempotency key set/cleared, retryable exception handling, non-retryable exception handling
        - Unit tests mock job classes and `RetryMapper.discard_exception?` to avoid dependencies
        - `rake spec` passes for aj_runner_activity_spec.rb
        - Code passes `rake rubocop`
    *   **Dependencies:** I1.T5 (Payload), I1.T6 (RetryMapper)
    *   **Parallelizable:** Yes (can run in parallel with I2.T2 if I1 is complete)

<!-- anchor: task-i2-t4 -->
*   **Task 2.4: Implement Workflow ID Builder Helper**
    *   **Task ID:** `I2.T4`
    *   **Description:** Create a helper method in `lib/activejob/temporal/adapter.rb` (or a separate helper module) for building deterministic workflow IDs. Implement `build_workflow_id(job)` method that returns a string in format `"ajwf:#{job.class.name}:#{job.job_id}"`. This ensures idempotent enqueue (same job_id → same workflow_id → Temporal rejects duplicate via `:reject` conflict policy). Write unit tests in `spec/unit/adapter_spec.rb` (this spec will be expanded in I3) covering: workflow ID format, determinism (same job → same ID), uniqueness across job classes. This is a small helper but critical for deduplication.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 3.7 (Interaction Flow - Workflow ID Generation), ActiveJob job structure
    *   **Input Files:** []
    *   **Target Files:**
        - `lib/activejob/temporal/adapter.rb` (create file with helper method, or add to existing module)
        - `spec/unit/adapter_spec.rb` (create or update)
    *   **Deliverables:** Working workflow ID builder, passing unit tests
    *   **Acceptance Criteria:**
        - `build_workflow_id(job)` returns string in format `"ajwf:<ClassName>:<job_id>"`
        - Example: For `SendInvoiceJob` with job_id "abc-123", returns `"ajwf:SendInvoiceJob:abc-123"`
        - Calling `build_workflow_id` twice with same job returns same string (deterministic)
        - Different job classes with same job_id return different workflow IDs (class name prevents collision)
        - Unit tests verify format and determinism
        - `rake spec` passes for adapter_spec.rb
        - Code passes `rake rubocop`
    *   **Dependencies:** None (can start immediately in I2)
    *   **Parallelizable:** Yes (can run in parallel with I2.T2, I2.T3)

<!-- anchor: task-i2-t5 -->
*   **Task 2.5: Implement Task Queue Resolver Helper**
    *   **Task ID:** `I2.T5`
    *   **Description:** Create a helper method in `lib/activejob/temporal/adapter.rb` (or helper module) for resolving Temporal task queue names from ActiveJob queue names. Implement `resolve_task_queue(job)` method that extracts `job.queue_name` (default to "default" if nil), applies `config.task_queue_prefix` (if present), and returns the final task queue string. Example: If `job.queue_name` is "billing" and `config.task_queue_prefix` is "prod-", return "prod-billing". If no prefix, return "billing". Write unit tests in `spec/unit/adapter_spec.rb` covering: task queue resolution with and without prefix, default queue name ("default"), nil queue_name handling.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 3.7 (Interaction Flow - Task Queue Resolution), configuration from I1.T3
    *   **Input Files:**
        - `lib/activejob/temporal.rb`
    *   **Target Files:**
        - `lib/activejob/temporal/adapter.rb` (updated with task queue resolver)
        - `spec/unit/adapter_spec.rb` (updated)
    *   **Deliverables:** Working task queue resolver, passing unit tests
    *   **Acceptance Criteria:**
        - `resolve_task_queue(job)` returns task queue string
        - If `job.queue_name` is "billing" and `config.task_queue_prefix` is nil, returns "billing"
        - If `job.queue_name` is "billing" and `config.task_queue_prefix` is "prod-", returns "prod-billing"
        - If `job.queue_name` is nil, returns "default" (or "prod-default" with prefix)
        - Unit tests cover all scenarios: with prefix, without prefix, nil queue_name, explicit queue_name
        - `rake spec` passes for adapter_spec.rb
        - Code passes `rake rubocop`
    *   **Dependencies:** I1.T3 (Configuration for task_queue_prefix)
    *   **Parallelizable:** Yes (can run in parallel with I2.T2, I2.T3, I2.T4)

<!-- anchor: task-i2-t6 -->
*   **Task 2.6: Run Rubocop and Fix Style Issues**
    *   **Task ID:** `I2.T6`
    *   **Description:** Run `rake rubocop` on all code written in Iteration 2 (workflows, activities, adapter helpers). Fix any Rubocop offenses. Ensure code adheres to Ruby style guide. Update `.rubocop.yml` if needed with justified exceptions. Acceptance: `rake rubocop` passes with zero offenses.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Rubocop configuration, code from I2.T2-I2.T5
    *   **Input Files:**
        - `lib/activejob/temporal/workflows/aj_workflow.rb`
        - `lib/activejob/temporal/activities/aj_runner_activity.rb`
        - `lib/activejob/temporal/adapter.rb`
        - `spec/unit/workflows/*.rb`
        - `spec/unit/activities/*.rb`
        - `spec/unit/adapter_spec.rb`
        - `.rubocop.yml`
    *   **Target Files:** All Ruby files in `lib/activejob/temporal/workflows/`, `lib/activejob/temporal/activities/`, `lib/activejob/temporal/adapter.rb`, and corresponding specs (updated with style fixes)
    *   **Deliverables:** Clean code passing Rubocop checks
    *   **Acceptance Criteria:**
        - `rake rubocop` exits with status 0 (zero offenses)
        - All auto-correctable offenses are fixed
        - Any manual fixes are applied
        - If `.rubocop.yml` is updated, changes are documented
    *   **Dependencies:** I2.T2, I2.T3, I2.T4, I2.T5 (all code must be written)
    *   **Parallelizable:** No (must run after all code is written)

<!-- anchor: task-i2-t7 -->
*   **Task 2.7: Run Unit Tests and Verify Coverage**
    *   **Task ID:** `I2.T7`
    *   **Description:** Run `rake spec` to execute all unit tests for Iteration 2 (workflows, activities, adapter helpers). Verify SimpleCov reports >= 90% code coverage for all new modules. If coverage is below 90%, write additional tests. Generate coverage report. Acceptance: All tests pass, coverage >= 90%.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** RSpec configuration, SimpleCov, unit tests from I2.T2-I2.T5
    *   **Input Files:**
        - `spec/spec_helper.rb`
        - `spec/unit/workflows/*.rb`
        - `spec/unit/activities/*.rb`
        - `spec/unit/adapter_spec.rb`
    *   **Target Files:** None (verification task, generates coverage report)
    *   **Deliverables:** Passing test suite, coverage report >= 90%
    *   **Acceptance Criteria:**
        - `rake spec` exits with status 0 (all tests pass)
        - SimpleCov report shows >= 90% coverage for `lib/activejob/temporal/workflows/*.rb`, `lib/activejob/temporal/activities/*.rb`, and adapter helpers
        - Coverage report is generated in `coverage/index.html`
        - No skipped or pending tests
    *   **Dependencies:** I2.T2, I2.T3, I2.T4, I2.T5 (all unit tests must be written)
    *   **Parallelizable:** No (must run after all tests are written)
