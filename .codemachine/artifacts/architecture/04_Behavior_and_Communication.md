# System Architecture Blueprint: activejob-temporal

**Version:** 1.0
**Date:** 2025-10-25

---

<!-- anchor: behavior-and-communication -->
## 3. Behavior & Communication

<!-- anchor: api-design-and-communication -->
### 3.7. API Design & Communication

<!-- anchor: api-style -->
#### **API Style**

**Primary API: Ruby Method Calls (Internal Gem API)**

The activejob-temporal gem exposes three primary API surfaces:

1. **ActiveJob Adapter Interface** (Rails → Gem)
   - **Style**: Implements `ActiveJob::QueueAdapters::AbstractAdapter` contract
   - **Methods**: `enqueue(job)`, `enqueue_at(job, timestamp)`
   - **Communication**: Synchronous Ruby method invocation within Rails process

2. **Temporal Client API** (Gem → Temporal Cluster)
   - **Style**: gRPC-based remote procedure calls
   - **Protocol**: `temporalio/api-go` protobuf definitions over HTTP/2 + gRPC
   - **Key Operations**: `start_workflow`, `get_workflow_handle`, `handle.cancel`, `handle.describe`

3. **Worker Execution API** (Temporal → Gem)
   - **Style**: Temporal SDK callback invocation
   - **Methods**: `AjWorkflow.execute(payload)`, `AjRunnerActivity.execute(payload)`
   - **Communication**: Synchronous Ruby method invocation within worker process

**No REST/GraphQL API**: This gem is a library, not a web service. All APIs are in-process or via Temporal's gRPC protocol.

**Rationale**: Ruby method calls are idiomatic for Rails gems; gRPC is Temporal's standard protocol (high performance, bi-directional streaming for long polling).

---

<!-- anchor: communication-patterns -->
#### **Communication Patterns**

**Pattern 1: Synchronous Request/Response (Rails → Temporal)**

- **Use Case**: Enqueuing a job via `perform_later`
- **Flow**: Rails calls `adapter.enqueue(job)` → Adapter calls `client.start_workflow` → Temporal cluster returns workflow ID or error
- **Blocking**: The enqueue call blocks until Temporal confirms workflow creation (typically <100ms)
- **Error Handling**: Raises `ActiveJob::EnqueueError` if Temporal cluster is unreachable

**Pattern 2: Long Polling (Worker → Temporal)**

- **Use Case**: Workers waiting for workflow/activity tasks
- **Flow**: Worker calls `Temporalio::Worker.run` → SDK polls Temporal's task queues → Temporal pushes tasks when available
- **Blocking**: Long-poll connections (up to 60s timeout) with automatic reconnection
- **Efficiency**: No busy-waiting; workers idle until tasks arrive

**Pattern 3: Asynchronous Activity Execution (Temporal → Worker)**

- **Use Case**: Running the actual job logic
- **Flow**: Temporal schedules activity → Worker picks up task → Executes `AjRunnerActivity.execute` → Reports result back to Temporal
- **Non-Blocking (from Workflow perspective)**: Workflow state is persisted; worker failure doesn't lose progress
- **Retries**: Handled automatically by Temporal's `RetryPolicy`

**Pattern 4: Best-Effort Cancellation (Rails → Temporal → Worker)**

- **Use Case**: User wants to abort an in-flight job
- **Flow**: Rails calls `ActiveJob::Temporal.cancel(job_id)` → Gem calls `handle.cancel` → Temporal sends cancellation signal → Worker receives signal during activity execution
- **Non-Blocking**: Cancel call returns immediately (doesn't wait for activity to stop)
- **Requires Heartbeating**: Activity must call `Temporalio::Activity.heartbeat` to detect cancellation promptly

---

<!-- anchor: interaction-flow-enqueue -->
#### **Key Interaction Flow 1: Job Enqueue (Immediate Execution)**

**Scenario**: Rails application enqueues a job for immediate execution via `perform_later`.

**Diagram:**

~~~plantuml
@startuml
actor "Developer" as Dev
participant "Rails App" as Rails
participant "ActiveJob" as AJ
participant "TemporalAdapter" as Adapter
participant "Payload Serializer" as Payload
participant "Retry Mapper" as Retry
participant "Search Attrs" as Search
participant "Temporal Client" as Client
participant "Temporal Cluster" as Temporal

Dev -> Rails : SendInvoiceJob.perform_later(42)
Rails -> AJ : perform_later(42)
AJ -> AJ : job = new SendInvoiceJob\n job.job_id = UUID.generate\n job.arguments = [42]

AJ -> Adapter : enqueue(job)
activate Adapter

Adapter -> Payload : from_job(job)
Payload --> Adapter : serialized_payload\n {job_class, job_id, arguments, ...}

Adapter -> Retry : for(SendInvoiceJob)
Retry -> SendInvoiceJob : inspect retry_on/discard_on metadata
Retry --> Adapter : RetryPolicy\n {initial: 30s, max_attempts: 5, ...}

Adapter -> Search : for(job)
Search --> Adapter : {ajClass: "SendInvoiceJob", ajQueue: "billing", ...}

Adapter -> Adapter : workflow_id = "ajwf:SendInvoiceJob:#{job.job_id}"
Adapter -> Adapter : task_queue = "billing"

Adapter -> Client : client.start_workflow(\n  AjWorkflow, \n  serialized_payload,\n  id: workflow_id,\n  task_queue: task_queue,\n  id_conflict_policy: :reject,\n  search_attributes: {...}\n)
Client -> Temporal : gRPC StartWorkflowExecution
Temporal --> Client : workflow_run (id, run_id)
Client --> Adapter : workflow_run

deactivate Adapter

Adapter --> AJ : (void, enqueue successful)
AJ --> Rails : (void)
Rails --> Dev : (returns immediately)

note right of Temporal
  Workflow is now queued
  on "billing" task queue
end note

@enduml
~~~

**Key Steps:**

1. **Developer calls `perform_later`**: Rails ActiveJob captures job class, arguments, and generates a UUID `job_id`
2. **ActiveJob calls adapter**: Invokes `TemporalAdapter.enqueue(job)`
3. **Payload serialization**: Converts ActiveJob arguments to JSON-compatible format
4. **Retry policy mapping**: Inspects job class's `retry_on`/`discard_on` declarations, builds Temporal `RetryPolicy`
5. **Search attributes building**: Extracts metadata (`ajClass`, `ajQueue`, etc.) for Temporal visibility
6. **Workflow ID generation**: Creates deterministic ID `ajwf:SendInvoiceJob:<job_id>` (enables deduplication)
7. **Task queue resolution**: Maps job's `queue_name` to Temporal task queue (with optional prefix)
8. **Temporal workflow start**: Calls `client.start_workflow` (gRPC to Temporal cluster)
9. **Temporal persists workflow**: Creates workflow in `Scheduled` state, returns workflow run handle
10. **Enqueue completes**: Rails call returns immediately (doesn't wait for job to execute)

**Communication Protocols:**
- Rails ↔ Gem: Ruby method calls (in-process)
- Gem ↔ Temporal: gRPC over HTTP/2 (network call, ~50-100ms latency)

---

<!-- anchor: interaction-flow-enqueue-scheduled -->
#### **Key Interaction Flow 2: Job Enqueue (Scheduled Execution)**

**Scenario**: Rails application schedules a job to run 5 minutes in the future via `set(wait: 5.minutes).perform_later`.

**Diagram:**

~~~plantuml
@startuml
actor "Developer" as Dev
participant "Rails App" as Rails
participant "ActiveJob" as AJ
participant "TemporalAdapter" as Adapter
participant "Temporal Client" as Client
participant "Temporal Cluster" as Temporal

Dev -> Rails : SendInvoiceJob.set(wait: 5.minutes).perform_later(42)
Rails -> AJ : set(wait: 5.minutes).perform_later(42)
AJ -> AJ : job.scheduled_at = Time.now + 5.minutes

AJ -> Adapter : enqueue_at(job, job.scheduled_at.to_i)
activate Adapter

Adapter -> Adapter : Serialize payload with scheduled_at timestamp
Adapter -> Client : client.start_workflow(\n  AjWorkflow,\n  payload: {..., scheduled_at: "2025-10-25T12:05:00Z"},\n  ...\n)
Client -> Temporal : gRPC StartWorkflowExecution
Temporal --> Client : workflow_run

deactivate Adapter

note right of Temporal
  Workflow starts immediately,
  but first action is Workflow.sleep(5.minutes)
  No worker thread is blocked!
end note

@enduml
~~~

**Key Differences from Immediate Enqueue:**

1. **ActiveJob captures `scheduled_at`**: Rails calculates the timestamp when job should run
2. **Adapter passes `scheduled_at` in payload**: Serialized as ISO8601 string
3. **Workflow starts immediately**: Temporal creates the workflow right away (not delayed on Temporal side)
4. **Workflow sleeps internally**: `AjWorkflow.execute` calls `Workflow.sleep(5.minutes)` before executing activity
5. **Durable delay**: If worker crashes during sleep, Temporal restores workflow state and continues sleep upon restart

**Why Not Use Temporal Schedules or Start Delay?**

- **v0.1 Simplicity**: `Workflow.sleep` is simple and well-tested
- **Future Enhancement**: v0.2 may add Temporal Schedules for recurring jobs

---

<!-- anchor: interaction-flow-execution -->
#### **Key Interaction Flow 3: Workflow & Activity Execution**

**Scenario**: A Temporal worker picks up the workflow task, executes the workflow logic, then executes the activity (actual job).

**Diagram:**

~~~plantuml
@startuml
participant "Temporal Cluster" as Temporal
participant "Worker" as Worker
participant "AjWorkflow" as Workflow
participant "AjRunnerActivity" as Activity
participant "Payload Serializer" as Payload
participant "Job Class\n(SendInvoiceJob)" as Job
participant "External API\n(Invoice Service)" as External

Temporal -> Worker : Poll: workflow task available on "billing" queue
Worker -> Workflow : execute(payload)
activate Workflow

alt Scheduled Job (has scheduled_at)
  Workflow -> Workflow : delay = scheduled_at - Workflow.now
  Workflow -> Temporal : Workflow.sleep(delay)
  note right
    Worker can process other tasks
    State persisted in Temporal
  end note
  Temporal --> Workflow : Timer fired
end

Workflow -> Temporal : execute_activity(\n  AjRunnerActivity,\n  payload,\n  start_to_close_timeout: 15.minutes,\n  retry: RetryPolicy {...}\n)
deactivate Workflow

Temporal -> Worker : Poll: activity task available
Worker -> Activity : execute(payload)
activate Activity

Activity -> Payload : deserialize_args(payload)
Payload --> Activity : args = [42]

Activity -> Activity : Thread.current[:aj_temporal_idempotency_key] = \n  "ajwf:SendInvoiceJob:#{job_id}/runner"

Activity -> Job : job = SendInvoiceJob.new\n job.perform(42)
activate Job

Job -> External : POST /invoices/42/send
External --> Job : 200 OK

Job --> Activity : (void, success)
deactivate Job

Activity -> Activity : Thread.current[:aj_temporal_idempotency_key] = nil
Activity --> Worker : (void, activity complete)
deactivate Activity

Worker -> Temporal : Report activity complete
Temporal -> Workflow : Activity result received
Workflow --> Temporal : Workflow complete
Temporal -> Temporal : Mark workflow as Completed

@enduml
~~~

**Key Steps:**

1. **Worker polls for workflow task**: Long-poll request to Temporal, receives workflow task
2. **Workflow execution begins**: Worker invokes `AjWorkflow.execute(payload)`
3. **(Optional) Sleep**: If `scheduled_at` is set and in the future, workflow calls `Workflow.sleep`
   - **Crucially**: Worker thread is **not blocked**; it returns to poll for other tasks
   - Temporal persists a timer event in workflow history
4. **Workflow schedules activity**: Calls `execute_activity(AjRunnerActivity, payload, ...)`
5. **Workflow task completes**: Worker reports back to Temporal; workflow enters "Waiting for activity" state
6. **Worker polls for activity task**: Receives activity task from Temporal
7. **Activity execution begins**: Worker invokes `AjRunnerActivity.execute(payload)`
8. **Payload deserialization**: Converts JSON payload back to Ruby job arguments
9. **Idempotency key set**: Stores workflow/activity identifiers in `Thread.current` (app code can read this)
10. **Job instantiation & execution**: Creates `SendInvoiceJob` instance, calls `job.perform(42)`
11. **Job logic runs**: Makes external API calls, database writes, etc.
12. **Activity completes**: Returns to worker, which reports success to Temporal
13. **Workflow completes**: Temporal marks workflow as `Completed`, archives to history

**Error Handling (Activity Retries):**

If `job.perform` raises an exception:

~~~plantuml
@startuml
participant "AjRunnerActivity" as Activity
participant "Job Class" as Job
participant "Error Mapper" as ErrorMapper
participant "Retry Mapper" as RetryMapper
participant "Temporal Cluster" as Temporal

Activity -> Job : job.perform(42)
Job --> Activity : raise PSP::TransientError

Activity -> ErrorMapper : map_exception(error, job_class)
ErrorMapper -> RetryMapper : discard_exception?(SendInvoiceJob, error)
RetryMapper --> ErrorMapper : false (not in discard_on list)

ErrorMapper --> Activity : Re-raise original exception

Activity --> Temporal : Activity failed: PSP::TransientError
Temporal -> Temporal : Check RetryPolicy: attempt 1/5, wait 30s
Temporal -> Temporal : Sleep 30s (durable timer)
Temporal -> Temporal : Schedule activity retry (attempt 2)

note right of Temporal
  Activity will be retried up to 5 times
  with exponential backoff (30s, 60s, 120s, ...)
end note

@enduml
~~~

**Non-Retryable Exceptions (`discard_on`):**

If the exception is in the `discard_on` list:

~~~plantuml
@startuml
participant "AjRunnerActivity" as Activity
participant "Job Class" as Job
participant "Error Mapper" as ErrorMapper
participant "Retry Mapper" as RetryMapper
participant "Temporal Cluster" as Temporal

Activity -> Job : job.perform(42)
Job --> Activity : raise PSP::FatalError

Activity -> ErrorMapper : map_exception(error, job_class)
ErrorMapper -> RetryMapper : discard_exception?(SendInvoiceJob, error)
RetryMapper --> ErrorMapper : true (in discard_on list)

ErrorMapper --> Activity : Raise ApplicationError(\n  message: "Fatal error",\n  non_retryable: true,\n  cause: error\n)

Activity --> Temporal : Activity failed (non-retryable)
Temporal -> Temporal : Mark activity as Failed (no retry)
Temporal -> Temporal : Workflow fails (activity failure bubbles up)

@enduml
~~~

---

<!-- anchor: interaction-flow-cancellation -->
#### **Key Interaction Flow 4: Job Cancellation**

**Scenario**: User cancels an in-flight job via `ActiveJob::Temporal.cancel(job_id)`.

**Diagram:**

~~~plantuml
@startuml
actor "Developer/Admin" as Dev
participant "Rails App" as Rails
participant "Cancellation API" as Cancel
participant "Temporal Client" as Client
participant "Temporal Cluster" as Temporal
participant "Worker" as Worker
participant "AjRunnerActivity" as Activity

Dev -> Rails : ActiveJob::Temporal.cancel("job-uuid-123")
Rails -> Cancel : cancel("job-uuid-123")
activate Cancel

Cancel -> Cancel : workflow_id = "ajwf:SendInvoiceJob:job-uuid-123"
Cancel -> Client : handle = client.get_workflow_handle(workflow_id)
Client -> Temporal : gRPC GetWorkflowExecutionHistory (brief check)
Temporal --> Client : Workflow exists, status: Running

Cancel -> Client : handle.cancel
Client -> Temporal : gRPC RequestCancelWorkflowExecution
Temporal --> Client : Cancellation requested

Cancel --> Rails : (void, returns immediately)
deactivate Cancel

note right of Temporal
  Cancellation signal sent,
  but activity may not abort instantly
end note

Temporal -> Worker : Deliver cancellation signal (if activity is running)

alt Activity is heartbeating
  Worker -> Activity : Temporalio::Activity.heartbeat
  Activity -> Temporal : Heartbeat RPC
  Temporal --> Activity : CancelledError (exception)
  Activity -> Activity : Catch CancelledError, cleanup, re-raise
  Activity --> Worker : Activity cancelled
  Worker -> Temporal : Report activity cancelled
  Temporal -> Temporal : Mark workflow as Cancelled
else Activity is NOT heartbeating
  note right of Activity
    Activity continues to completion
    Cancellation only takes effect
    after activity finishes
  end note
  Activity --> Worker : Activity completes normally
  Worker -> Temporal : Activity complete
  Temporal -> Temporal : Workflow still receives cancellation,\n  completes with Cancelled status
end

@enduml
~~~

**Key Steps:**

1. **User calls cancellation API**: `ActiveJob::Temporal.cancel(job_id)`
2. **Build workflow ID**: Deterministic ID constructed from job class and job_id
3. **Get workflow handle**: Temporal client retrieves handle to running workflow
4. **Send cancellation**: gRPC `RequestCancelWorkflowExecution` call (non-blocking, returns immediately)
5. **Temporal propagates signal**: Sends cancellation to workflow and any running activities
6. **(If activity heartbeats)**: Activity receives `CancelledError`, can abort early
7. **(If no heartbeat)**: Activity completes normally; workflow still marked as cancelled afterward

**Best Practice**: Jobs should call `Temporalio::Activity.heartbeat` periodically (e.g., every 30s) to enable prompt cancellation.

---

<!-- anchor: communication-error-handling -->
#### **Communication Error Handling**

**Enqueue-Time Errors:**

| Error Scenario | Exception Raised | Handling |
|----------------|------------------|----------|
| Temporal cluster unreachable | `ActiveJob::EnqueueError` | Rails rescues, may retry or log |
| Payload too large (>250KB) | `ActiveJob::SerializationError` | Rails rescues, job not enqueued |
| Invalid arguments (non-serializable) | `ActiveJob::SerializationError` | Rails rescues, job not enqueued |
| Workflow ID collision (duplicate `job_id`) | `Temporalio::Client::WorkflowAlreadyStartedError` | Silently ignored (idempotent enqueue) |

**Execution-Time Errors:**

| Error Scenario | Handling | Outcome |
|----------------|----------|---------|
| Activity timeout (>15min) | Temporal raises `Temporalio::Activity::TimeoutError` | Activity fails, workflow retries per `RetryPolicy` |
| Worker crash during activity | Temporal detects heartbeat timeout | Activity scheduled on another worker |
| Exception in `job.perform` | Caught by `AjRunnerActivity`, mapped to `ApplicationError` | Retried per `retry_on` or marked non-retryable per `discard_on` |
| Workflow code bug (non-determinism) | Temporal raises `Temporalio::Workflow::NondeterminismError` | Workflow stuck, requires code fix + reset |

**Communication Timeouts:**

- **gRPC call timeout**: 10s default (configurable via `temporalio`)
- **Activity start-to-close timeout**: 15 minutes default (configurable)
- **Workflow execution timeout**: None (workflows can run indefinitely if sleeping)

---

<!-- anchor: api-versioning -->
#### **API Versioning & Compatibility**

**Gem Versioning (SemVer):**

- **v0.1.x**: Initial release, single workflow/activity
- **v0.2.x**: Additive features (Schedules, tracing enhancements) – backward compatible
- **v0.3.x**: New features (Signals, child workflows) – may require opt-in
- **v1.0.x**: Stable API, breaking changes only in major versions

**Temporal Workflow Versioning:**

- **v0.1**: No explicit versioning (assumes all workers run same gem version)
- **Future**: Use Temporal's `Workflow.patch` or workflow versioning API for safe deployments

**Backward Compatibility Promise:**

- Existing jobs (enqueued in v0.1) will continue to run in v0.2+ workers
- Workflow/activity signatures are stable across minor versions
- Configuration changes are additive (old configs remain valid)
