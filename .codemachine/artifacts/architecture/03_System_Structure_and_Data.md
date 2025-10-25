# System Architecture Blueprint: activejob-temporal

**Version:** 1.0
**Date:** 2025-10-25

---

<!-- anchor: system-structure-and-data -->
## 3. System Structure & Data

<!-- anchor: system-context-diagram -->
### 3.3. System Context Diagram (C4 Level 1)

**Description:**

This diagram shows the **system boundary** of activejob-temporal and its interactions with external actors and systems. The gem sits between a Rails application (which enqueues jobs) and the Temporal cluster (which orchestrates their execution). Workers run the gem's code to poll for and execute activities.

**Key Actors & Systems:**
- **Rails Application**: The system that uses ActiveJob to enqueue background jobs
- **activejob-temporal Gem**: The adapter library (system under design)
- **Temporal Cluster**: External orchestration platform (workflows, history, search)
- **Temporal Worker Processes**: Separate processes that poll task queues and execute workflow/activity code
- **External Systems**: Any third-party APIs or services that jobs interact with (e.g., payment gateways, email services)

**Diagram:**

~~~plantuml
@startuml
!include https://raw.githubusercontent.com/plantuml-stdlib/C4-PlantUML/master/C4_Context.puml

LAYOUT_WITH_LEGEND()

title System Context Diagram - activejob-temporal Gem

Person(developer, "Rails Developer", "Writes ActiveJob jobs")
System_Boundary(rails_app, "Rails Application") {
  System(app, "Rails App", "Uses ActiveJob API to enqueue jobs")
}

System(gem, "activejob-temporal Gem", "ActiveJob adapter that translates jobs into Temporal workflows")

System_Ext(temporal, "Temporal Cluster", "Durable workflow orchestration platform (workflows, activities, history)")

System_Boundary(worker_boundary, "Temporal Worker Processes") {
  System(worker, "Worker Process", "Polls task queues, executes workflows & activities")
}

System_Ext(external, "External Systems", "Payment gateways, email services, APIs")

Rel(developer, app, "Writes jobs using", "Ruby/ActiveJob DSL")
Rel(app, gem, "Calls perform_later", "Ruby method call")
Rel(gem, temporal, "Starts workflows", "gRPC/Temporal Client API")
Rel(worker, temporal, "Polls for tasks", "gRPC/Long polling")
Rel(worker, gem, "Executes workflow/activity code", "Ruby method invocation")
Rel(worker, external, "Calls APIs", "HTTPS/REST/GraphQL")
Rel_Back(temporal, app, "Provides visibility", "Temporal Web UI")

@enduml
~~~

---

<!-- anchor: container-diagram -->
### 3.4. Container Diagram (C4 Level 2)

**Description:**

This diagram zooms into the **activejob-temporal gem** and shows its major internal components (containers in C4 terminology, though here they're Ruby modules/classes). It also shows how the gem interacts with Rails, the Temporal cluster, and worker processes.

**Key Containers:**
- **TemporalAdapter**: ActiveJob adapter implementation (entry point from Rails)
- **Temporal Client**: Memoized client connection to Temporal cluster
- **AjWorkflow**: Temporal workflow definition (orchestrates scheduling + activity execution)
- **AjRunnerActivity**: Temporal activity definition (executes actual job logic)
- **Configuration Module**: Gem configuration (target, namespace, timeouts, etc.)
- **Payload Serializer**: Converts ActiveJob arguments to/from JSON
- **Retry Mapper**: Translates `retry_on`/`discard_on` to Temporal `RetryPolicy`
- **Search Attributes Builder**: Constructs metadata for Temporal visibility
- **Cancellation API**: Exposes `ActiveJob::Temporal.cancel(job_id)`

**Diagram:**

~~~plantuml
@startuml
!include https://raw.githubusercontent.com/plantuml-stdlib/C4-PlantUML/master/C4_Container.puml

LAYOUT_WITH_LEGEND()

title Container Diagram - activejob-temporal Gem Internal Structure

Person(developer, "Rails Developer", "Writes ActiveJob jobs")

System_Boundary(rails, "Rails Application") {
  Container(rails_app, "Rails App", "Ruby/Rails", "Business logic, controllers, models")
  Container(activejob, "ActiveJob Framework", "Rails Gem", "Job queue abstraction")
}

System_Boundary(gem_boundary, "activejob-temporal Gem") {
  Container(adapter, "TemporalAdapter", "Ruby Class", "Implements ActiveJob::QueueAdapters::AbstractAdapter")
  Container(client, "Temporal Client", "Ruby Singleton", "Memoized connection to Temporal cluster")
  Container(config, "Configuration Module", "Ruby Module", "Stores target, namespace, timeouts, retry defaults")
  Container(payload, "Payload Serializer", "Ruby Module", "Serializes/deserializes ActiveJob::Arguments")
  Container(retry_mapper, "Retry Mapper", "Ruby Module", "Maps retry_on/discard_on → RetryPolicy")
  Container(search_attrs, "Search Attributes Builder", "Ruby Module", "Builds ajClass, ajQueue, ajJobId, etc.")
  Container(cancel_api, "Cancellation API", "Ruby Module", "Exposes .cancel(job_id)")

  Container(workflow, "AjWorkflow", "Temporal Workflow", "Orchestrates sleep + activity execution")
  Container(activity, "AjRunnerActivity", "Temporal Activity", "Executes job.perform(*args)")
}

System_Ext(temporal, "Temporal Cluster", "gRPC API", "Workflow orchestration, history storage, task queues")

System_Boundary(worker_boundary, "Temporal Worker Process") {
  Container(worker, "Worker", "Ruby Process", "Polls task queue, executes workflows & activities")
}

System_Ext(external, "External Systems", "APIs/Services", "Email, payments, webhooks")

' Rails → Gem
Rel(developer, rails_app, "Writes jobs", "Ruby")
Rel(rails_app, activejob, "Calls perform_later", "Ruby")
Rel(activejob, adapter, "Calls enqueue/enqueue_at", "Ruby")

' Adapter → Gem Components
Rel(adapter, payload, "Serializes job args", "Ruby")
Rel(adapter, retry_mapper, "Maps retry policies", "Ruby")
Rel(adapter, search_attrs, "Builds metadata", "Ruby")
Rel(adapter, config, "Reads settings", "Ruby")
Rel(adapter, client, "Starts workflow", "Ruby")

' Client → Temporal
Rel(client, temporal, "start_workflow API call", "gRPC")

' Worker → Temporal
Rel(worker, temporal, "Poll for tasks", "gRPC long-poll")

' Worker → Workflow/Activity
Rel(worker, workflow, "Executes workflow code", "Ruby")
Rel(worker, activity, "Executes activity code", "Ruby")

' Activity → Job
Rel(activity, payload, "Deserializes args", "Ruby")
Rel(activity, rails_app, "Instantiates & calls job.perform", "Ruby")

' Job → External
Rel(rails_app, external, "Makes API calls", "HTTPS")

' Cancellation
Rel(rails_app, cancel_api, "Calls .cancel(job_id)", "Ruby")
Rel(cancel_api, client, "Gets workflow handle", "Ruby")
Rel(cancel_api, temporal, "Calls handle.cancel", "gRPC")

@enduml
~~~

---

<!-- anchor: component-diagram -->
### 3.5. Component Diagram(s) (C4 Level 3)

**Description:**

This diagram details the internal components of the **TemporalAdapter** and **AjRunnerActivity** containers, showing the fine-grained modules and their interactions.

**Adapter Components:**
- **EnqueueHandler**: Handles `enqueue` calls
- **EnqueueAtHandler**: Handles `enqueue_at` calls (scheduled jobs)
- **WorkflowIdBuilder**: Generates deterministic workflow IDs
- **TaskQueueResolver**: Resolves task queue name from job queue + prefix

**Activity Components:**
- **JobInstantiator**: Deserializes payload and instantiates job class
- **ErrorMapper**: Maps exceptions to Temporal `ApplicationError` (retryable/non-retryable)
- **IdempotencyKeyProvider**: Sets Thread-local idempotency key

**Diagram (Focus: Adapter & Activity Internals):**

~~~plantuml
@startuml
!include https://raw.githubusercontent.com/plantuml-stdlib/C4-PlantUML/master/C4_Component.puml

LAYOUT_WITH_LEGEND()

title Component Diagram - TemporalAdapter & AjRunnerActivity Internals

Container_Boundary(adapter_boundary, "TemporalAdapter") {
  Component(enqueue_handler, "EnqueueHandler", "Ruby Method", "Handles immediate job enqueue")
  Component(enqueue_at_handler, "EnqueueAtHandler", "Ruby Method", "Handles scheduled job enqueue")
  Component(workflow_id_builder, "WorkflowIdBuilder", "Ruby Module", "Builds 'ajwf:<class>:<job_id>'")
  Component(task_queue_resolver, "TaskQueueResolver", "Ruby Module", "Resolves task queue from job.queue_name")
}

Container_Boundary(activity_boundary, "AjRunnerActivity") {
  Component(job_instantiator, "JobInstantiator", "Ruby Method", "Deserializes payload, creates job instance")
  Component(error_mapper, "ErrorMapper", "Ruby Module", "Maps discard_on → ApplicationError(non_retryable)")
  Component(idempotency_key, "IdempotencyKeyProvider", "Ruby Module", "Sets Thread.current[:aj_temporal_idempotency_key]")
}

Component_Ext(payload_module, "Payload Serializer", "Ruby Module", "from_job, deserialize_args")
Component_Ext(retry_mapper_module, "Retry Mapper", "Ruby Module", "for(job_class), discard_exception?")
Component_Ext(search_attrs_module, "Search Attributes Builder", "Ruby Module", "for(job)")
Component_Ext(client_module, "Temporal Client", "Ruby Singleton", ".client → Temporalio::Client")
Component_Ext(config_module, "Configuration", "Ruby Module", ".config → settings")

System_Ext(temporal_cluster, "Temporal Cluster", "gRPC API")
Container_Ext(job_class, "Job Class", "Rails ActiveJob", "User-defined job with perform method")

' Adapter flow
Rel(enqueue_handler, workflow_id_builder, "Calls", "Ruby")
Rel(enqueue_handler, task_queue_resolver, "Calls", "Ruby")
Rel(enqueue_handler, payload_module, "Calls from_job", "Ruby")
Rel(enqueue_handler, retry_mapper_module, "Calls for(job_class)", "Ruby")
Rel(enqueue_handler, search_attrs_module, "Calls for(job)", "Ruby")
Rel(enqueue_handler, client_module, "Calls .client.start_workflow", "Ruby")

Rel(enqueue_at_handler, workflow_id_builder, "Calls", "Ruby")
Rel(enqueue_at_handler, task_queue_resolver, "Calls", "Ruby")
Rel(enqueue_at_handler, payload_module, "Calls from_job(at: timestamp)", "Ruby")
Rel(enqueue_at_handler, client_module, "Calls .client.start_workflow", "Ruby")

Rel(client_module, temporal_cluster, "start_workflow", "gRPC")

' Activity flow
Rel(job_instantiator, payload_module, "Calls deserialize_args", "Ruby")
Rel(job_instantiator, job_class, "Instantiates & calls .perform", "Ruby")

Rel(job_instantiator, idempotency_key, "Sets Thread.current key", "Ruby")
Rel(job_instantiator, error_mapper, "Wraps exceptions", "Ruby")

Rel(error_mapper, retry_mapper_module, "Calls discard_exception?", "Ruby")

Rel(task_queue_resolver, config_module, "Reads .task_queue_prefix", "Ruby")
Rel(retry_mapper_module, config_module, "Reads retry defaults", "Ruby")

@enduml
~~~

---

<!-- anchor: data-model-overview -->
### 3.6. Data Model Overview & ERD

**Description:**

Unlike traditional queue-based systems, activejob-temporal does **not persist its own data** in a database. All state is managed by Temporal's history storage. However, there are key **data structures** (payloads, configurations, metadata) that flow through the system.

This section describes the **logical data model** of job payloads and Temporal metadata, not a relational database schema.

<!-- anchor: data-entities -->
#### **Key Data Entities**

**1. Job Payload (Workflow Input)**

The serialized representation of an ActiveJob that is passed to `AjWorkflow.execute`.

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `job_class` | String | Fully-qualified class name | `"SendInvoiceJob"` |
| `job_id` | String (UUID) | ActiveJob's unique identifier | `"a1b2c3d4-..."` |
| `queue_name` | String | ActiveJob queue name | `"billing"` |
| `arguments` | Array<Any> | Serialized job arguments (JSON-compatible) | `[42, {"key": "value"}]` |
| `scheduled_at` | ISO8601 String (optional) | Scheduled execution timestamp | `"2025-10-25T12:00:00Z"` |
| `executions` | Integer | Number of times job has been attempted | `0` (on first enqueue) |
| `exception_executions` | Hash | Retry metadata (from ActiveJob) | `{}` |

**2. Workflow Metadata (Temporal Search Attributes)**

Attached to the workflow on start, enabling queries in Temporal UI.

| Attribute | Type | Purpose | Example |
|-----------|------|---------|---------|
| `ajClass` | Keyword | Job class name for filtering | `"SendInvoiceJob"` |
| `ajQueue` | Keyword | Task queue/job queue | `"billing"` |
| `ajJobId` | Keyword | ActiveJob job_id for correlation | `"a1b2c3d4-..."` |
| `ajEnqueuedAt` | Datetime | Enqueue timestamp | `2025-10-25T12:00:00Z` |
| `ajTenantId` | Keyword (optional) | Multi-tenancy support | `"tenant-123"` |

**3. Retry Policy (Activity Configuration)**

Derived from ActiveJob's `retry_on`/`discard_on` DSL and passed to `execute_activity`.

| Field | Type | Source | Example |
|-------|------|--------|---------|
| `initial_interval` | Duration | `retry_on wait:` or config default | `30.seconds` |
| `backoff_coefficient` | Float | Config default (2.0) | `2.0` |
| `maximum_attempts` | Integer | `retry_on attempts:` or config default | `5` |
| `non_retryable_error_types` | Array<String> | `discard_on` exception classes | `["PSP::FatalError"]` |

**4. Configuration (Gem Settings)**

Stored in `ActiveJob::Temporal.config` singleton.

| Setting | Type | Default | Purpose |
|---------|------|---------|---------|
| `target` | String | `"127.0.0.1:7233"` | Temporal server address |
| `namespace` | String | `"default"` | Temporal namespace |
| `task_queue_prefix` | String (optional) | `nil` | Prefix for task queue names |
| `default_activity_timeout` | Duration | `15.minutes` | Activity start_to_close_timeout |
| `default_retry_initial_interval` | Duration | `30.seconds` | Retry initial delay |
| `default_retry_backoff` | Float | `2.0` | Exponential backoff factor |
| `default_retry_max_attempts` | Integer | `1` | Max retry attempts if no `retry_on` |
| `logger` | Logger | `Rails.logger` | Logging destination |
| `enable_tracing` | Boolean | `true` | OpenTelemetry tracing toggle |

<!-- anchor: data-model-erd -->
#### **Logical ERD (Temporal Workflow State)**

This diagram shows the **conceptual relationships** between Temporal entities (not a database schema, as Temporal manages persistence internally).

~~~plantuml
@startuml

' This is a conceptual ERD, not a database schema
' Temporal stores this data in its internal history database

entity "Temporal Workflow" as Workflow {
  *workflow_id : string <<PK>>
  --
  workflow_type : string (AjWorkflow)
  run_id : string
  task_queue : string
  execution_status : enum (running, completed, failed, canceled)
  start_time : timestamp
  close_time : timestamp
  search_attributes : jsonb
}

entity "Workflow Input (Job Payload)" as Input {
  *workflow_id : string <<FK>>
  --
  job_class : string
  job_id : string (UUID)
  queue_name : string
  arguments : jsonb
  scheduled_at : timestamp (optional)
}

entity "Activity Execution" as Activity {
  *activity_id : string <<PK>>
  *workflow_id : string <<FK>>
  --
  activity_type : string (AjRunnerActivity)
  attempt_number : integer
  start_time : timestamp
  close_time : timestamp
  status : enum (scheduled, started, completed, failed, canceled)
  result : jsonb (optional)
  failure_message : string (optional)
}

entity "Search Attributes" as SearchAttrs {
  *workflow_id : string <<FK>>
  --
  ajClass : string
  ajQueue : string
  ajJobId : string
  ajEnqueuedAt : timestamp
  ajTenantId : string (optional)
}

Workflow ||--|| Input : has
Workflow ||--o{ Activity : executes
Workflow ||--|| SearchAttrs : has

@enduml
~~~

<!-- anchor: data-persistence -->
#### **Data Persistence Strategy**

**Where Data Lives:**

| Data | Stored In | Lifetime | Access |
|------|-----------|----------|--------|
| **Workflow State** | Temporal History Service | Until retention policy expires | Temporal UI, gRPC API |
| **Job Arguments** | Workflow input (JSON blob) | Duration of workflow | Activity code |
| **Retry Metadata** | Activity execution history | Duration of workflow | Temporal UI |
| **Search Attributes** | Temporal Visibility Store | Duration of workflow + retention | Temporal UI queries |
| **Configuration** | Ruby process memory (config file/env vars) | Process lifetime | Gem code |

**No Separate Database Required:**

- activejob-temporal does **not** create database tables
- Temporal cluster handles all persistence (backed by PostgreSQL/Cassandra)
- Rails application may have its own database (for models referenced in job args via GlobalID)

**Payload Size Constraints:**

- **Max payload size**: 250KB (configurable, enforced at enqueue time)
- **Temporal limit**: 2MB per workflow history (includes all events, not just input)
- **Best Practice**: Pass references (IDs) rather than large objects; use GlobalID for ActiveRecord models
