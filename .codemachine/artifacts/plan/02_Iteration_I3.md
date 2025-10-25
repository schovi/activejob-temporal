# Project Plan: activejob-temporal Gem - Iteration 3

---

<!-- anchor: iteration-3-plan -->
### Iteration 3: ActiveJob Adapter & Cancellation API

*   **Iteration ID:** `I3`
*   **Goal:** Implement the ActiveJob adapter (`TemporalAdapter`) that integrates with Rails, and the cancellation API. This connects all previous components to enable actual job enqueue and cancellation.
*   **Prerequisites:** `I1` (Foundation modules), `I2` (Workflow and Activity implementation)
*   **Tasks:**

<!-- anchor: task-i3-t1 -->
*   **Task 3.1: Implement TemporalAdapter Core (enqueue method)**
    *   **Task ID:** `I3.T1`
    *   **Description:** Create `lib/activejob/temporal/adapter.rb` with the `ActiveJob::QueueAdapters::TemporalAdapter` class. This adapter must implement the ActiveJob adapter interface. Implement the `enqueue(job)` method with the following logic: (1) Serialize job payload using `Payload.from_job(job)`. (2) Validate payload size (<= 250KB); raise `ActiveJob::SerializationError` if exceeded. (3) Build workflow_id using `build_workflow_id(job)` (from I2.T4). (4) Resolve task_queue using `resolve_task_queue(job)` (from I2.T5). (5) Get retry policy using `RetryMapper.for(job.class)`. (6) Build search attributes using `SearchAttributes.for(job)`. (7) Get Temporal client using `ActiveJob::Temporal.client`. (8) Call `client.start_workflow(AjWorkflow, payload, id: workflow_id, task_queue: task_queue, id_conflict_policy: :reject, search_attributes: search_attrs)`. (9) Log enqueue event using `Logger.log_event("workflow_enqueued", {workflow_id: ..., job_class: ..., ...})`. (10) Handle errors: if `start_workflow` fails (e.g., Temporal unreachable), raise `ActiveJob::EnqueueError`. Return the workflow run handle (or nil, depending on ActiveJob adapter contract). Write unit tests in `spec/unit/adapter_spec.rb` covering: successful enqueue, payload serialization, workflow ID and task queue resolution, retry policy mapping, search attributes, error handling (Temporal unreachable, payload too large). Mock `client.start_workflow` to avoid real Temporal calls.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 3.7 (Key Interaction Flow: Enqueue), ActiveJob adapter interface documentation, all foundation modules (Payload, RetryMapper, SearchAttributes, Client, Logger), workflow ID/task queue helpers from I2.T4/I2.T5
    *   **Input Files:**
        - `lib/activejob/temporal/adapter.rb` (created in I2 with helpers, now expanded)
        - `lib/activejob/temporal/payload.rb`
        - `lib/activejob/temporal/retry_mapper.rb`
        - `lib/activejob/temporal/search_attributes.rb`
        - `lib/activejob/temporal/client.rb`
        - `lib/activejob/temporal/logger.rb`
        - `lib/activejob/temporal/workflows/aj_workflow.rb`
    *   **Target Files:**
        - `lib/activejob/temporal/adapter.rb` (updated with TemporalAdapter class and enqueue method)
        - `spec/unit/adapter_spec.rb` (updated with enqueue tests)
    *   **Deliverables:** Working `enqueue(job)` method in TemporalAdapter, passing unit tests covering all enqueue logic and error handling
    *   **Acceptance Criteria:**
        - `TemporalAdapter` class exists in `ActiveJob::QueueAdapters` namespace
        - `enqueue(job)` method is defined
        - Payload is serialized using `Payload.from_job(job)`
        - Payload size is validated; `SerializationError` raised if > 250KB
        - Workflow ID is built using `build_workflow_id(job)`
        - Task queue is resolved using `resolve_task_queue(job)`
        - Retry policy is retrieved using `RetryMapper.for(job.class)`
        - Search attributes are built using `SearchAttributes.for(job)`
        - `client.start_workflow` is called with correct parameters: `(AjWorkflow, payload, id:, task_queue:, id_conflict_policy: :reject, search_attributes:)`
        - Log event "workflow_enqueued" is written with workflow_id, job_class, queue, etc.
        - If `start_workflow` raises exception (mocked Temporal connection error), `ActiveJob::EnqueueError` is raised
        - Unit tests mock `client.start_workflow` and verify all parameters
        - Unit tests mock all dependencies (Payload, RetryMapper, SearchAttributes, Logger) to isolate adapter logic
        - `rake spec` passes for adapter_spec.rb (enqueue tests)
        - Code passes `rake rubocop`
    *   **Dependencies:** I1.T4 (Client), I1.T5 (Payload), I1.T6 (RetryMapper), I1.T7 (SearchAttributes), I1.T8 (Logger), I2.T2 (AjWorkflow reference), I2.T4 (workflow_id helper), I2.T5 (task_queue helper)
    *   **Parallelizable:** No (depends on many I1 and I2 tasks)

<!-- anchor: task-i3-t2 -->
*   **Task 3.2: Implement TemporalAdapter enqueue_at method (Scheduled Jobs)**
    *   **Task ID:** `I3.T2`
    *   **Description:** Extend `lib/activejob/temporal/adapter.rb` to implement the `enqueue_at(job, timestamp)` method for scheduled job execution. The logic is similar to `enqueue(job)`, but: (1) Convert `timestamp` (Unix timestamp integer) to `Time` object. (2) Pass `scheduled_at: timestamp` to `Payload.from_job(job, scheduled_at: timestamp)`. The rest of the flow is identical to `enqueue(job)`: serialize payload, validate size, build workflow_id, resolve task_queue, get retry policy, build search attributes, start workflow. The workflow itself (AjWorkflow) will handle the sleep logic. Write unit tests in `spec/unit/adapter_spec.rb` covering: enqueue_at with future timestamp, payload includes scheduled_at, workflow started immediately (not delayed on Temporal side), log event includes scheduled_at. Mock `client.start_workflow` as before.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 3.7 (Key Interaction Flow: Scheduled Enqueue), ActiveJob adapter interface, Payload module from I1.T5, enqueue logic from I3.T1
    *   **Input Files:**
        - `lib/activejob/temporal/adapter.rb`
        - `lib/activejob/temporal/payload.rb`
    *   **Target Files:**
        - `lib/activejob/temporal/adapter.rb` (updated with enqueue_at method)
        - `spec/unit/adapter_spec.rb` (updated with enqueue_at tests)
    *   **Deliverables:** Working `enqueue_at(job, timestamp)` method, passing unit tests
    *   **Acceptance Criteria:**
        - `enqueue_at(job, timestamp)` method is defined in TemporalAdapter
        - Timestamp (integer) is converted to Time object
        - `Payload.from_job(job, scheduled_at: time_object)` is called
        - Payload includes `scheduled_at` field in ISO8601 format
        - Workflow is started immediately (no delay on Temporal side; `start_workflow` called right away)
        - Log event includes `scheduled_at` attribute
        - Unit tests verify: `enqueue_at` with future timestamp, payload structure, workflow start parameters
        - Unit tests mock `client.start_workflow` and `Payload.from_job`
        - `rake spec` passes for adapter_spec.rb (enqueue_at tests)
        - Code passes `rake rubocop`
    *   **Dependencies:** I3.T1 (enqueue method must be implemented first to reuse logic)
    *   **Parallelizable:** No (extends I3.T1)

<!-- anchor: task-i3-t3 -->
*   **Task 3.3: Implement TemporalAdapter enqueue_after_transaction_commit? method**
    *   **Task ID:** `I3.T3`
    *   **Description:** Add `enqueue_after_transaction_commit?` method to `TemporalAdapter` class. This method should return `true` to tell ActiveJob to defer enqueue until after database transaction commits (Rails 6.1+ feature). This prevents jobs from being enqueued for rolled-back transactions. Implementation is trivial: `def enqueue_after_transaction_commit?; true; end`. Write unit test in `spec/unit/adapter_spec.rb` verifying this method returns `true`.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** ActiveJob adapter interface documentation (enqueue_after_transaction_commit? feature)
    *   **Input Files:**
        - `lib/activejob/temporal/adapter.rb`
    *   **Target Files:**
        - `lib/activejob/temporal/adapter.rb` (updated with enqueue_after_transaction_commit? method)
        - `spec/unit/adapter_spec.rb` (updated with test)
    *   **Deliverables:** Method implementation, passing unit test
    *   **Acceptance Criteria:**
        - `enqueue_after_transaction_commit?` method is defined in TemporalAdapter
        - Method returns `true`
        - Unit test verifies return value
        - `rake spec` passes for adapter_spec.rb
        - Code passes `rake rubocop`
    *   **Dependencies:** I3.T1 (adapter must exist)
    *   **Parallelizable:** Yes (can run in parallel with I3.T2 or I3.T4)

<!-- anchor: task-i3-t4 -->
*   **Task 3.4: Register TemporalAdapter with ActiveJob**
    *   **Task ID:** `I3.T4`
    *   **Description:** Ensure the `TemporalAdapter` is properly registered with ActiveJob so it can be selected via `config.active_job.queue_adapter = :temporal` in Rails configuration. This typically requires the adapter to be defined in the `ActiveJob::QueueAdapters` namespace (already done in I3.T1) and to be auto-loadable by Rails. Create a test Rails initializer example in `examples/basic_rails_app/config/initializers/active_job.rb` (if examples directory exists) or document in README placeholder. Write an integration-style test (can be unit-level with mocking) in `spec/unit/adapter_spec.rb` that verifies Rails can load the adapter via `ActiveJob::QueueAdapters.lookup(:temporal)` and returns `TemporalAdapter` class. This ensures proper naming and namespace conventions are followed.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** ActiveJob adapter registration conventions, Rails auto-loading patterns
    *   **Input Files:**
        - `lib/activejob/temporal/adapter.rb`
    *   **Target Files:**
        - `lib/activejob/temporal/adapter.rb` (verify namespace and naming)
        - `spec/unit/adapter_spec.rb` (add adapter lookup test)
        - `examples/basic_rails_app/config/initializers/active_job.rb` (optional example)
    *   **Deliverables:** Verified adapter registration, passing test for adapter lookup
    *   **Acceptance Criteria:**
        - `ActiveJob::QueueAdapters::TemporalAdapter` class exists
        - `ActiveJob::QueueAdapters.lookup(:temporal)` returns `TemporalAdapter` class
        - Unit test verifies adapter lookup
        - Example initializer created (optional, or documented in README)
        - `rake spec` passes for adapter_spec.rb (lookup test)
        - Code passes `rake rubocop`
    *   **Dependencies:** I3.T1 (adapter must exist)
    *   **Parallelizable:** Yes (can run in parallel with I3.T2, I3.T3)

<!-- anchor: task-i3-t5 -->
*   **Task 3.5: Implement Cancellation API**
    *   **Task ID:** `I3.T5`
    *   **Description:** Create `lib/activejob/temporal/cancel.rb` with the cancellation API module. Implement `ActiveJob::Temporal.cancel(job_id)` class method with the following logic: (1) Build workflow_id from job_id. This requires knowing the job class name, but job_id alone is not sufficient (workflow_id format is `ajwf:<ClassName>:<job_id>`). **Problem**: We don't have job class from just job_id. **Solution**: Modify workflow_id format to NOT include class name, just use job_id directly (breaking change to earlier decision), OR require caller to pass job class: `cancel(job_class, job_id)`. **Recommendation**: Use `cancel(job_class, job_id)` for v0.1 to maintain deterministic workflow_id format. Implement `cancel(job_class, job_id)` that: (1) Builds workflow_id = `"ajwf:#{job_class.name}:#{job_id}"`. (2) Gets Temporal client using `ActiveJob::Temporal.client`. (3) Gets workflow handle: `handle = client.get_workflow_handle(workflow_id)`. (4) Calls `handle.cancel`. (5) Logs cancellation event. (6) Handles errors: if workflow not found or already completed, log warning but don't raise exception (best-effort cancellation). Write unit tests in `spec/unit/cancel_spec.rb` covering: successful cancellation, workflow not found error handling, logging. Mock `client.get_workflow_handle` and `handle.cancel`.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Section 3.7 (Key Interaction Flow: Cancellation), Client module from I1.T4, Logger from I1.T8, workflow_id format from I2.T4
    *   **Input Files:**
        - `lib/activejob/temporal/client.rb`
        - `lib/activejob/temporal/logger.rb`
    *   **Target Files:**
        - `lib/activejob/temporal/cancel.rb`
        - `spec/unit/cancel_spec.rb`
        - `lib/activejob/temporal.rb` (update to include cancel module and expose .cancel class method)
    *   **Deliverables:** Working cancellation API, passing unit tests, documented API method
    *   **Acceptance Criteria:**
        - `ActiveJob::Temporal.cancel(job_class, job_id)` method is defined
        - Workflow ID is built correctly: `"ajwf:#{job_class.name}:#{job_id}"`
        - `client.get_workflow_handle(workflow_id)` is called
        - `handle.cancel` is called
        - Log event "cancellation_requested" is written with workflow_id, job_class, job_id
        - If workflow not found (handle raises exception), error is caught, warning logged, method returns gracefully (doesn't raise)
        - Unit tests mock `client.get_workflow_handle` and `handle.cancel`
        - Unit tests verify: successful cancel, workflow not found handling, logging
        - `rake spec` passes for cancel_spec.rb
        - Code passes `rake rubocop`
        - API is documented in code comments (YARD format: `@param job_class [Class]`, `@param job_id [String]`, `@return [void]`)
    *   **Dependencies:** I1.T4 (Client), I1.T8 (Logger), I2.T4 (workflow_id format understanding)
    *   **Parallelizable:** Yes (can run in parallel with I3.T1-I3.T4 if I1 and I2 are complete)

<!-- anchor: task-i3-t6 -->
*   **Task 3.6: Update Cancellation Sequence Diagram**
    *   **Task ID:** `I3.T6`
    *   **Description:** Review and update the cancellation sequence diagram created in I2.T1 (`docs/diagrams/cancellation_sequence.puml`) to reflect the actual implementation from I3.T5. Ensure the diagram shows the correct method signature (`cancel(job_class, job_id)`) and flow. Update any notes to clarify best-effort cancellation behavior (requires heartbeating for prompt abort). Verify diagram renders correctly.
    *   **Agent Type Hint:** `DocumentationAgent`
    *   **Inputs:** Cancellation API implementation from I3.T5, original sequence diagram from I2.T1
    *   **Input Files:**
        - `docs/diagrams/cancellation_sequence.puml`
        - `lib/activejob/temporal/cancel.rb`
    *   **Target Files:**
        - `docs/diagrams/cancellation_sequence.puml` (updated)
    *   **Deliverables:** Updated and accurate cancellation sequence diagram
    *   **Acceptance Criteria:**
        - Diagram reflects `cancel(job_class, job_id)` method signature
        - Diagram shows workflow_id construction, handle retrieval, cancel call
        - Diagram includes notes about best-effort cancellation and heartbeating requirement
        - Diagram renders without syntax errors in PlantUML
    *   **Dependencies:** I3.T5 (cancellation API must be implemented)
    *   **Parallelizable:** No (depends on I3.T5 for actual implementation details)

<!-- anchor: task-i3-t7 -->
*   **Task 3.7: Run Rubocop and Fix Style Issues**
    *   **Task ID:** `I3.T7`
    *   **Description:** Run `rake rubocop` on all code written in Iteration 3 (adapter, cancellation). Fix any Rubocop offenses. Update `.rubocop.yml` if needed. Acceptance: `rake rubocop` passes with zero offenses.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** Rubocop configuration, code from I3.T1-I3.T5
    *   **Input Files:**
        - `lib/activejob/temporal/adapter.rb`
        - `lib/activejob/temporal/cancel.rb`
        - `spec/unit/adapter_spec.rb`
        - `spec/unit/cancel_spec.rb`
        - `.rubocop.yml`
    *   **Target Files:** All Ruby files in `lib/activejob/temporal/adapter.rb`, `lib/activejob/temporal/cancel.rb`, and corresponding specs (updated with style fixes)
    *   **Deliverables:** Clean code passing Rubocop checks
    *   **Acceptance Criteria:**
        - `rake rubocop` exits with status 0 (zero offenses)
        - All auto-correctable offenses are fixed
        - Any manual fixes are applied
        - If `.rubocop.yml` is updated, changes are documented
    *   **Dependencies:** I3.T1, I3.T2, I3.T3, I3.T5 (all code must be written)
    *   **Parallelizable:** No (must run after all code is written)

<!-- anchor: task-i3-t8 -->
*   **Task 3.8: Run Unit Tests and Verify Coverage**
    *   **Task ID:** `I3.T8`
    *   **Description:** Run `rake spec` to execute all unit tests for Iteration 3 (adapter, cancellation). Verify SimpleCov reports >= 90% code coverage for adapter and cancel modules. If coverage is below 90%, write additional tests. Generate coverage report. Acceptance: All tests pass, coverage >= 90%.
    *   **Agent Type Hint:** `BackendAgent`
    *   **Inputs:** RSpec configuration, SimpleCov, unit tests from I3.T1-I3.T5
    *   **Input Files:**
        - `spec/spec_helper.rb`
        - `spec/unit/adapter_spec.rb`
        - `spec/unit/cancel_spec.rb`
    *   **Target Files:** None (verification task, generates coverage report)
    *   **Deliverables:** Passing test suite, coverage report >= 90%
    *   **Acceptance Criteria:**
        - `rake spec` exits with status 0 (all tests pass)
        - SimpleCov report shows >= 90% coverage for `lib/activejob/temporal/adapter.rb` and `lib/activejob/temporal/cancel.rb`
        - Coverage report is generated in `coverage/index.html`
        - No skipped or pending tests
    *   **Dependencies:** I3.T1, I3.T2, I3.T3, I3.T5 (all unit tests must be written)
    *   **Parallelizable:** No (must run after all tests are written)
