# System Architecture Blueprint: activejob-temporal

**Version:** 1.0
**Date:** 2025-10-25

---

<!-- anchor: proposed-architecture -->
## 3. Proposed Architecture

<!-- anchor: architectural-style -->
### 3.1. Architectural Style

**Primary Style: Adapter + Orchestration Pattern**

The activejob-temporal gem employs a **layered adapter architecture** that bridges two distinct execution models:

1. **Rails ActiveJob Layer**: The familiar Rails job abstraction with its DSL (`perform_later`, `retry_on`, etc.)
2. **Temporal Orchestration Layer**: Durable workflows and activities with guaranteed execution semantics

**Architectural Pattern Rationale:**

The architecture is fundamentally an **Adapter Pattern** implementation:
- The `TemporalAdapter` translates ActiveJob's `enqueue`/`enqueue_at` calls into Temporal workflow starts
- A single, simple **Orchestration Workflow** (`AjWorkflow`) acts as a durable scheduler and executor
- A single **Activity** (`AjRunnerActivity`) provides the execution context for actual job logic

This is **not** a microservices architecture (no network-based service boundaries), nor a traditional queue-based system. Instead, it's a **durability wrapper** that uses Temporal's orchestration engine as a fault-tolerant job executor.

**Key Characteristics:**

| Aspect | ActiveJob (Traditional) | activejob-temporal (Temporal) |
|--------|-------------------------|-------------------------------|
| **Execution Model** | Queue-based, polling workers | Workflow-based, durable state machine |
| **Scheduling** | Redis/DB timers or worker threads | Temporal Workflow.sleep (non-blocking) |
| **Retries** | In-process or queue-level retries | Temporal Activity RetryPolicy (durable) |
| **State Persistence** | External (Redis/DB) | Built-in (Temporal history) |
| **Failure Recovery** | Job re-enqueue or DLQ | Automatic workflow/activity retry |
| **Observability** | Logs + custom metrics | Temporal UI + Search Attributes + Logs |

**Why This Style?**

1. **Minimal Code Changes**: Rails developers change only the adapter line; no job code modifications
2. **Durable-by-Default**: Temporal's workflow engine provides fault tolerance without additional infrastructure
3. **Operational Simplicity**: No need for separate Redis/Postgres for job state; Temporal handles persistence
4. **Clear Separation**: The adapter, workflow, and activity have distinct responsibilities:
   - **Adapter**: Translates ActiveJob → Temporal
   - **Workflow**: Orchestrates scheduling and activity invocation
   - **Activity**: Executes the actual job logic (the only place side effects occur)

**Architectural Constraints Enforced:**

- **Workflow Determinism**: `AjWorkflow` contains no I/O, only `sleep` and `execute_activity`
- **Activity Idempotency**: `AjRunnerActivity` may re-execute on retries; must be idempotent
- **Stateless Workers**: Workers are horizontally scalable with no shared state

---

<!-- anchor: technology-stack-summary -->
### 3.2. Technology Stack Summary

<!-- anchor: tech-stack-core -->
#### **Core Technologies**

| Component | Technology | Version | Rationale |
|-----------|-----------|---------|-----------|
| **Language** | Ruby | >= 4.0 | Modern Fiber scheduler, performance improvements, Rails compatibility |
| **Framework** | Rails (ActiveJob) | >= 7.2 | ActiveJob API stability, broad adoption, transactional callback support |
| **Orchestration Engine** | Temporal | Server 1.22+ | Production-proven durable execution, rich observability, strong consistency |
| **Temporal SDK** | `temporalio` | GA (Oct 2025+) | Official Ruby SDK with workflow/activity primitives, native code performance |

<!-- anchor: tech-stack-dependencies -->
#### **Key Dependencies**

| Dependency | Purpose | Required? |
|------------|---------|-----------|
| `temporalio` | Temporal client, workflow, activity runtime | **Yes** |
| `activejob` (via Rails) | Job abstraction, serialization, DSL | **Yes** |
| `globalid` (via Rails) | Serialize ActiveRecord models as job arguments | **Yes** |
| `opentelemetry-sdk` | Distributed tracing spans | Optional |
| `semantic_logger` | Structured logging (JSON output) | Optional (falls back to `Logger`) |

<!-- anchor: tech-stack-no-external-services -->
#### **What's NOT Required (Comparison to Traditional Stacks)**

Unlike Sidekiq/Resque/Delayed Job stacks, this gem does **NOT** require:
- ❌ Redis (no separate queue storage)
- ❌ PostgreSQL job tables (no `delayed_jobs` schema)
- ❌ Separate scheduler process (Temporal handles scheduling)
- ❌ Custom retry/DLQ infrastructure (Temporal provides this)

**Trade-off**: Introduces dependency on Temporal server cluster (adds operational complexity, but offloads job orchestration concerns).

<!-- anchor: tech-stack-serialization -->
#### **Serialization & Data Formats**

| Data | Format | Library |
|------|--------|---------|
| **Job Arguments** | JSON (via `ActiveJob::Arguments`) | Rails built-in |
| **Workflow Input/Output** | JSON (Temporal default) | `temporalio` |
| **Activity Input/Output** | JSON | `temporalio` |
| **Logs** | JSON (structured) | `semantic_logger` or `Logger` |

**Constraint**: All job arguments must be JSON-serializable or GlobalID-compatible. Complex Ruby objects (Procs, Threads, etc.) are rejected at enqueue time.

<!-- anchor: tech-stack-deployment -->
#### **Deployment Stack**

| Component | Technology | Notes |
|-----------|-----------|-------|
| **Process Manager** | systemd, Docker Compose, Kubernetes | Workers must run as persistent processes |
| **Containerization** | Docker (optional) | Recommended for Kubernetes deployments |
| **Orchestration** | Kubernetes, ECS, Nomad (optional) | Horizontal worker scaling |
| **Temporal Server** | Self-hosted or Temporal Cloud | Requires PostgreSQL/Cassandra backend (managed separately) |

<!-- anchor: tech-stack-observability -->
#### **Observability Stack**

| Layer | Technology | Integration Point |
|-------|-----------|-------------------|
| **Logging** | Rails.logger, `semantic_logger` | Gem writes structured logs to Rails logger |
| **Tracing** | OpenTelemetry | Optional interceptor in `temporalio` |
| **Metrics** | Temporal built-in metrics | Exposed via Temporal UI (v0.1); Prometheus in v0.2+ |
| **Workflow Visibility** | Temporal Web UI | Search Attributes query interface |

<!-- anchor: tech-stack-rationale -->
#### **Technology Selection Rationale**

**Why Temporal over Traditional Queues?**

1. **Durable Scheduling**: `Workflow.sleep` is persisted; worker restarts don't lose scheduled jobs
2. **Built-in Retries**: No need to implement retry logic; declarative `RetryPolicy`
3. **Rich Visibility**: Temporal UI provides workflow history, stack traces, search
4. **Consistency**: Workflows are versioned; safe code deployments during in-flight jobs
5. **Cancellation**: First-class support for aborting in-flight work

**Why Ruby SDK (not Go/Java/Python)?**

- **Rails Ecosystem Fit**: Native Ruby integration with ActiveJob, no FFI overhead
- **Developer Familiarity**: Rails teams already use Ruby; no polyglot complexity
- **Fiber-Based Concurrency**: Ruby 4 keeps worker execution aligned with the repository runtime baseline

**Why Single Workflow/Activity (v0.1)?**

- **Simplicity**: Matches ActiveJob's mental model (one job = one unit of work)
- **Proven Pattern**: Most background jobs are simple, single-step tasks
- **Extensibility**: Future versions can introduce multi-activity workflows for orchestration use cases

**Payload Size Limit (250KB)**

- **Temporal Constraint**: Default history size limits (2MB per workflow) → conservative 250KB per job
- **Best Practice**: Large payloads should use object storage (S3) + pass references in job args
