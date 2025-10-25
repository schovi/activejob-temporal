# System Architecture Blueprint: activejob-temporal

**Version:** 1.0
**Date:** 2025-10-25

---

<!-- anchor: design-rationale-and-tradeoffs -->
## 4. Design Rationale & Trade-offs

<!-- anchor: key-decisions-summary -->
### 4.1. Key Decisions Summary

This section summarizes the most critical architectural decisions and their rationale.

<!-- anchor: decision-single-workflow-activity -->
#### **Decision 1: Single Workflow + Single Activity Pattern**

**Choice:** Implement one `AjWorkflow` that executes one `AjRunnerActivity` per job.

**Rationale:**

- **Simplicity**: Maps directly to ActiveJob's mental model (one job = one unit of work)
- **Proven Pattern**: Most background jobs are simple, single-step tasks; multi-activity orchestration is rare
- **Ease of Migration**: Existing ActiveJob jobs work without modification
- **Minimal Workflow Code**: Reduces risk of non-determinism bugs (fewer moving parts)

**Trade-offs:**

| Benefit | Cost |
|---------|------|
| Easy to understand and debug | Cannot orchestrate multi-step workflows natively (v0.1) |
| Fast implementation (smaller codebase) | Less flexible for complex job chains |
| Stable workflow logic (less likely to change) | Requires external orchestration for job dependencies |

**Alternatives Considered:**

1. **Multi-Activity Workflow**: Allow jobs to define multiple activities
   - **Rejected**: Too complex for v0.1; most jobs are single-step
2. **Dynamic Workflow Generation**: Generate workflow classes per job type
   - **Rejected**: Over-engineering; single workflow handles all cases

**Future Evolution:** v0.3 may introduce optional multi-activity workflows for advanced use cases.

---

<!-- anchor: decision-workflow-id-deduplication -->
#### **Decision 2: Deterministic Workflow ID + :reject Conflict Policy**

**Choice:** Generate workflow IDs as `ajwf:<JobClass>:<job_id>` with `:reject` conflict policy.

**Rationale:**

- **Idempotency**: Prevents duplicate job execution if `perform_later` is called twice (e.g., due to retry logic)
- **Debuggability**: Workflow ID embeds job class and UUID, making it easy to correlate in logs/UI
- **Temporal Best Practice**: Workflow IDs should be deterministic and meaningful

**Trade-offs:**

| Benefit | Cost |
|---------|------|
| Guarantees no duplicate workflows | Cannot re-enqueue same job_id (must generate new UUID) |
| Easy to find workflows in Temporal UI | Workflow ID collisions raise errors (not silent failures) |

**Alternatives Considered:**

1. **Random Workflow IDs**: Generate UUID for each workflow
   - **Rejected**: Loses deduplication; same job could run twice
2. **Use Only job_id**: Workflow ID = job_id (no class prefix)
   - **Rejected**: Collisions across job classes (e.g., two jobs with same UUID)

**Caveat**: If job_id is reused across different job classes, collisions still occur (addressed by including class name in ID).

---

<!-- anchor: decision-workflow-sleep -->
#### **Decision 3: Workflow.sleep for Scheduled Jobs (Not Start Delay)**

**Choice:** Use `Workflow.sleep` inside `AjWorkflow.execute` for `set(wait:)` jobs, rather than Temporal's start delay.

**Rationale:**

- **Consistency**: All workflows start immediately, state is always in "Running" (visible in Temporal UI)
- **Durable**: Sleep is persisted in workflow history; worker crashes don't lose scheduled time
- **Non-Blocking**: Workers don't hold threads during sleep (can process other tasks)
- **Simplicity**: No need to manage separate timer tasks or scheduled workflows

**Trade-offs:**

| Benefit | Cost |
|---------|------|
| Workflows appear in Temporal UI immediately | Slight workflow history overhead (one timer event) |
| Worker threads not blocked during sleep | Workflow runs for full duration (even if just sleeping) |
| Easy to cancel scheduled jobs (workflow handle exists) | Cannot query "jobs scheduled for future" via list filters |

**Alternatives Considered:**

1. **Temporal Start Delay**: Set workflow start time in the future
   - **Rejected**: Workflow doesn't exist until start time; harder to cancel or query
2. **External Timer Service**: Use Rails scheduler or cron to enqueue at scheduled time
   - **Rejected**: Requires separate infrastructure; loses Temporal's durability

**Future Enhancement:** v0.2 may add Temporal Schedules API for recurring jobs (cron-like patterns).

---

<!-- anchor: decision-retry-mapping -->
#### **Decision 4: Map retry_on/discard_on to Temporal RetryPolicy**

**Choice:** Translate ActiveJob's `retry_on`/`discard_on` DSL to Temporal's activity `RetryPolicy` at enqueue time.

**Rationale:**

- **Familiar API**: Rails developers use existing ActiveJob retry DSL; no Temporal-specific syntax
- **Durable Retries**: Temporal manages retry backoff and state; survives worker crashes
- **Exponential Backoff**: Temporal's built-in backoff prevents thundering herd on downstream services

**Trade-offs:**

| Benefit | Cost |
|---------|------|
| No code changes for existing jobs | Mapping logic adds complexity (retry_mapper module) |
| Temporal's retry is battle-tested | Cannot use Rails-specific retry features (e.g., callbacks) |
| Retries survive worker crashes | Must restart activity from beginning (no partial retry) |

**Alternatives Considered:**

1. **In-Activity Retry Logic**: Implement retries inside `AjRunnerActivity.execute`
   - **Rejected**: Loses Temporal's durable retry state; harder to debug
2. **No Retry Mapping**: Require jobs to use Temporal-specific retry syntax
   - **Rejected**: Breaks ActiveJob compatibility; increases learning curve

**Limitation**: If a job has multiple `retry_on` declarations, only the first matching exception is used (by ancestry order).

---

<!-- anchor: decision-search-attributes -->
#### **Decision 5: Search Attributes for Visibility**

**Choice:** Attach `ajClass`, `ajQueue`, `ajJobId`, `ajEnqueuedAt`, `ajTenantId` as Search Attributes on workflow start.

**Rationale:**

- **Operational Queries**: Operators can filter workflows by job class, queue, or tenant in Temporal UI
- **Debugging**: Easy to find specific jobs by ActiveJob job_id
- **Monitoring**: Track job enqueue times, detect stale jobs

**Trade-offs:**

| Benefit | Cost |
|---------|------|
| Rich filtering in Temporal UI | Search Attributes must be pre-registered in Temporal schema |
| Fast queries (indexed) | Limited to keyword/datetime types (no arbitrary JSON) |
| Multi-tenant support (ajTenantId) | Requires Temporal cluster with Elasticsearch (for advanced search) |

**Alternatives Considered:**

1. **No Search Attributes**: Rely only on workflow history
   - **Rejected**: Hard to find jobs without full workflow ID; poor operational experience
2. **Custom Metadata Store**: Store job metadata in separate database
   - **Rejected**: Adds complexity; duplicates Temporal's built-in visibility

**Configuration Requirement**: Temporal cluster must have these Search Attributes registered:

```bash
tctl admin cluster add-search-attributes \
  --name ajClass --type Keyword \
  --name ajQueue --type Keyword \
  --name ajJobId --type Keyword \
  --name ajEnqueuedAt --type Datetime \
  --name ajTenantId --type Keyword
```

---

<!-- anchor: decision-no-activerecord-callbacks -->
#### **Decision 6: No Custom ActiveJob Callbacks**

**Choice:** Do not intercept or wrap ActiveJob callbacks (`before_enqueue`, `after_perform`, etc.) in v0.1.

**Rationale:**

- **Simplicity**: Callbacks remain in job class, executed normally during `perform`
- **Rails Ownership**: Let Rails handle callback lifecycle; adapter only handles enqueue/execute
- **Temporal Neutrality**: Temporal doesn't need to know about Rails-specific callback semantics

**Trade-offs:**

| Benefit | Cost |
|---------|------|
| No callback interference | Cannot inject Temporal-specific logic into callbacks (e.g., heartbeats) |
| Jobs remain portable (can switch adapters) | Callback failures are not tracked separately in Temporal |

**Future Enhancement:** v0.3 may add opt-in callback hooks for advanced use cases (e.g., heartbeat in `around_perform`).

---

<!-- anchor: alternatives-considered -->
### 4.2. Alternatives Considered

This section explores significant alternative approaches that were evaluated but not selected for v0.1.

<!-- anchor: alternative-queue-based-adapter -->
#### **Alternative 1: Queue-Based Temporal Adapter (Hybrid Approach)**

**Description:** Keep existing job queue (Sidekiq/Resque) as primary, use Temporal only for scheduled jobs or retries.

**Why Considered:**

- Minimal disruption to existing infrastructure
- Gradual migration path

**Why Rejected:**

- **Complexity**: Two job systems to maintain (queue + Temporal)
- **Split Brain**: Hard to track jobs across two systems
- **Limited Benefits**: Doesn't leverage Temporal's full durability guarantees
- **Goal Mismatch**: Spec requires full Temporal integration, not hybrid

**Verdict:** All-in on Temporal is simpler for v0.1; hybrid may be future migration path for large apps.

---

<!-- anchor: alternative-multi-activity-workflow -->
#### **Alternative 2: Multi-Activity Workflow (Job Chains)**

**Description:** Allow jobs to define dependencies (e.g., "run JobB after JobA succeeds") and execute them in one workflow.

**Why Considered:**

- Supports complex orchestration (ETL pipelines, multi-step workflows)
- Reduces workflow overhead (one workflow for multiple jobs)

**Why Rejected:**

- **Out of Scope for v0.1**: Spec explicitly lists "multi-activity orchestration" as non-goal
- **Complexity**: Requires DSL for job dependencies, error handling across activities
- **Rare Use Case**: Most background jobs are independent; chaining is handled externally (e.g., job calls another job)

**Verdict:** Defer to v0.3; v0.1 focuses on simple, single-job execution.

---

<!-- anchor: alternative-signals-for-cancellation -->
#### **Alternative 3: Temporal Signals for Cancellation (Instead of handle.cancel)**

**Description:** Use Temporal Signals to send cancellation requests to workflows, allowing custom cancellation logic.

**Why Considered:**

- More flexible (workflow can decide how to cancel)
- Can pass cancellation reason/metadata

**Why Rejected:**

- **Overkill for v0.1**: Simple jobs don't need custom cancellation logic
- **Spec Uses handle.cancel**: Spec explicitly calls `handle.cancel` (standard Temporal pattern)
- **Added Complexity**: Requires signal handler in workflow, more code to maintain

**Verdict:** Use standard `handle.cancel` in v0.1; consider Signals in v0.3 for advanced workflows.

---

<!-- anchor: alternative-temporal-schedules -->
#### **Alternative 4: Temporal Schedules API (For set(wait:))**

**Description:** Use Temporal's Schedules API to trigger workflows at specific times, instead of `Workflow.sleep`.

**Why Considered:**

- Native Temporal feature for scheduled execution
- Workflows don't "run" until scheduled time (cleaner history)

**Why Rejected:**

- **Schedules API is for Recurring Jobs**: Designed for cron-like patterns, not one-off delays
- **Workflow.sleep is Simpler**: No need to manage separate schedule entities
- **Spec Requires set(wait:)**: ActiveJob's `set(wait:)` is one-off delay, not recurring

**Verdict:** Use `Workflow.sleep` for v0.1; add Schedules API in v0.2 for recurring jobs (e.g., `perform_every`).

---

<!-- anchor: known-risks-and-mitigation -->
### 4.3. Known Risks & Mitigation

<!-- anchor: risk-temporal-sdk-maturity -->
#### **Risk 1: Temporal SDK Ruby Maturity**

**Risk:** The `temporalio/sdk-ruby` is relatively new (GA in October 2025); may have bugs or missing features.

**Likelihood:** Medium (new SDK, less battle-tested than Go/Java SDKs)

**Impact:** High (blocking bugs could prevent production use)

**Mitigation:**

- **Pin SDK Version**: Lock gem to specific SDK version in `Gemfile.lock`
- **Comprehensive Testing**: Write integration tests with Temporal test server
- **Monitor SDK Issues**: Watch GitHub issues for bug reports, update proactively
- **Fallback Plan**: If critical bugs found, consider Go SDK via FFI (complex) or delay release

**Status:** Accept risk; Ruby SDK team is actively developing and responsive.

---

<!-- anchor: risk-payload-size-bloat -->
#### **Risk 2: Payload Size Bloat**

**Risk:** Developers accidentally serialize large objects (images, reports) as job arguments, exceeding Temporal's history limits.

**Likelihood:** Medium (common mistake in background job systems)

**Impact:** Medium (workflows fail with history size errors; hard to debug)

**Mitigation:**

- **Enforce 250KB Limit**: Raise `SerializationError` at enqueue time if payload > 250KB
- **Documentation**: Clearly document best practices (use GlobalID, S3 references)
- **Warnings**: Log warnings for payloads > 100KB (below hard limit)
- **Code Reviews**: Add linter rule to flag large serialized objects

**Status:** Mitigated via hard limit + documentation.

---

<!-- anchor: risk-non-deterministic-workflows -->
#### **Risk 3: Non-Deterministic Workflow Code**

**Risk:** Future changes to `AjWorkflow.execute` logic (e.g., adding I/O, randomness) break in-flight workflows.

**Likelihood:** Low (v0.1 workflow is very simple)

**Impact:** High (workflows stuck, require manual intervention)

**Mitigation:**

- **Code Reviews**: Strict review of workflow code changes
- **Temporal Versioning (v0.2+)**: Use `Workflow.patch` or workflow versioning for safe changes
- **Testing**: Write determinism tests (replay workflow history with new code)
- **Documentation**: Clearly document determinism rules for contributors

**Status:** Low risk for v0.1 (workflow is static); plan versioning for v0.2.

---

<!-- anchor: risk-temporal-cluster-downtime -->
#### **Risk 4: Temporal Cluster Downtime**

**Risk:** Temporal cluster becomes unavailable (network partition, outage); jobs cannot be enqueued or executed.

**Likelihood:** Low (if using Temporal Cloud or HA self-hosted setup)

**Impact:** High (all background jobs stall)

**Mitigation:**

- **Use Temporal Cloud**: SLA-backed availability (99.9% uptime)
- **Self-Hosted HA**: Multi-region deployment, database replication
- **Circuit Breaker**: Detect Temporal downtime, return `EnqueueError` quickly (don't block Rails requests)
- **Alerting**: Monitor Temporal cluster health, alert on downtime
- **Graceful Degradation**: Consider fallback to Redis queue (not in v0.1)

**Status:** Accept risk; rely on Temporal Cloud SLA or ops team for HA setup.

---

<!-- anchor: risk-worker-resource-exhaustion -->
#### **Risk 5: Worker Resource Exhaustion**

**Risk:** High job volume or memory leaks cause workers to crash or slow down.

**Likelihood:** Medium (common in production job systems)

**Impact:** Medium (jobs delayed, backlog grows)

**Mitigation:**

- **Resource Limits**: Set Kubernetes memory/CPU limits, prevent OOM kills
- **Horizontal Scaling**: Add more workers to handle load
- **Activity Concurrency Tuning**: Adjust `max_concurrent_activity_task_executions` based on resources
- **Memory Profiling**: Use `memory_profiler` to detect leaks in job code
- **Monitoring**: Track worker memory/CPU usage, set alerts

**Status:** Standard ops concern; mitigated via monitoring + scaling.

---

<!-- anchor: risk-migration-from-existing-queue -->
#### **Risk 6: Migration from Existing Job Queue (Sidekiq/Resque)**

**Risk:** Switching from existing queue to Temporal loses in-flight jobs or causes duplicate execution.

**Likelihood:** High (migrations always have edge cases)

**Impact:** Medium (job loss or duplicates)

**Mitigation:**

- **Dual-Write Period**: Run both queues in parallel during migration
- **Drain Old Queue**: Stop new enqueues, let old jobs finish before switching
- **Idempotency**: Ensure job logic is idempotent (mitigates duplicates)
- **Testing**: Test migration on staging environment with production-like load
- **Rollback Plan**: Keep old queue config ready to revert

**Status:** Not in scope for v0.1; document migration guide for v1.0.

---

<!-- anchor: future-considerations -->
## 5. Future Considerations

<!-- anchor: potential-evolution -->
### 5.1. Potential Evolution

This section outlines how the architecture can evolve to support future features and scale.

<!-- anchor: evolution-v02 -->
#### **v0.2: Schedules, Tracing, Rate Limiting**

**New Features:**

- **Temporal Schedules API**: Support recurring jobs (cron-like patterns)
  - New DSL: `perform_every(interval, at:)` or `perform_cron("0 9 * * *")`
  - Maps to Temporal Schedules
- **Enhanced OpenTelemetry**: Interceptor for automatic span creation
  - No code changes; enable via config
- **Per-Queue Rate Limiting**: Prevent queue overload
  - Use Temporal rate limiters or custom activity throttling

**Architectural Changes:**

- Add `ScheduleAdapter` module (parallel to `TemporalAdapter`)
- Introduce `AjScheduleWorkflow` for recurring jobs
- Add rate limiter middleware in worker

**Backward Compatibility:** Fully compatible; existing jobs continue to work.

---

<!-- anchor: evolution-v03 -->
#### **v0.3: Signals, Queries, Updates, Child Workflows**

**New Features:**

- **Signals**: Send messages to running workflows
  - Use case: Pause/resume jobs, update job parameters
  - API: `ActiveJob::Temporal.signal(job_id, signal_name, payload)`
- **Queries**: Read workflow state without side effects
  - Use case: Check job progress, read intermediate results
  - API: `ActiveJob::Temporal.query(job_id, query_name)`
- **Updates**: Synchronous signal with validation
  - Use case: Update job arguments mid-execution
- **Child Workflows**: Spawn sub-workflows from jobs
  - Use case: Fan-out pattern (e.g., bulk email: parent workflow → child per email)

**Architectural Changes:**

- Add signal/query handlers to `AjWorkflow`
- Introduce `with_child_workflows` DSL for jobs
- Add `AjChildWorkflow` class for sub-workflows

**Backward Compatibility:** Opt-in features; existing jobs unaffected.

---

<!-- anchor: evolution-v10 -->
#### **v1.0: Stable API, Migration Tooling, Rails Generators**

**Goals:**

- **API Stability**: Lock public API, commit to SemVer
- **Migration Guide**: Comprehensive docs for Sidekiq/Resque → Temporal migration
- **Rails Generators**: `rails g activejob:temporal:install` (generates config, worker script)
- **Advanced Configuration**: Per-job timeout overrides, custom retry policies
- **Prometheus Metrics**: Expose gem-level metrics for monitoring

**Architectural Changes:**

- Finalize configuration DSL
- Add plugin system for custom adapters/interceptors
- Support Temporal workflow versioning (safe code deployments)

**Maturity:** Production-ready for large-scale Rails apps.

---

<!-- anchor: evolution-scale -->
#### **Scaling to Millions of Jobs**

**Current Limits (v0.1):**

- **Workflows**: Temporal can handle millions of concurrent workflows
- **Activities**: Limited by worker concurrency (100 per worker)
- **Search Attributes**: Elasticsearch-backed, scales horizontally

**Future Optimizations:**

1. **Activity Batching**: Group multiple jobs into one activity (reduce workflow overhead)
2. **Sticky Workers**: Pin activities to workers with warm caches (reduce cold starts)
3. **Custom Data Converters**: Compress payloads (protobuf instead of JSON)
4. **Sharded Task Queues**: Partition queues by tenant/region for isolation

**Diagram (Future Multi-Tenant Architecture):**

~~~plantuml
@startuml
!include https://raw.githubusercontent.com/plantuml-stdlib/C4-PlantUML/master/C4_Container.puml

title Future Multi-Tenant Architecture (v0.3+)

Person(tenant_a, "Tenant A Users", "")
Person(tenant_b, "Tenant B Users", "")

System_Boundary(rails, "Rails Application") {
  Container(app, "Rails App", "Multi-tenant")
}

System_Boundary(gem, "activejob-temporal") {
  Container(adapter, "TemporalAdapter", "Routes jobs by tenant")
}

System_Boundary(temporal, "Temporal Cluster") {
  Container(namespace_a, "Namespace: tenant-a", "Isolated workflows")
  Container(namespace_b, "Namespace: tenant-b", "Isolated workflows")
}

System_Boundary(workers, "Workers") {
  Container(worker_a, "Worker Pool A", "Polls tenant-a namespace")
  Container(worker_b, "Worker Pool B", "Polls tenant-b namespace")
}

Rel(tenant_a, app, "Enqueues jobs", "")
Rel(tenant_b, app, "Enqueues jobs", "")

Rel(app, adapter, "Calls perform_later", "")

Rel(adapter, namespace_a, "Starts workflows (tenant A)", "")
Rel(adapter, namespace_b, "Starts workflows (tenant B)", "")

Rel(worker_a, namespace_a, "Executes workflows", "")
Rel(worker_b, namespace_b, "Executes workflows", "")

@enduml
~~~

**Key Feature:** Separate Temporal namespaces per tenant, preventing cross-tenant job interference.

---

<!-- anchor: areas-for-deeper-dive -->
### 5.2. Areas for Deeper Dive

The following areas require more detailed design before implementation:

<!-- anchor: deeper-dive-workflow-versioning -->
#### **1. Workflow Versioning & Safe Deployments**

**Challenge:** How to change `AjWorkflow` logic without breaking in-flight workflows?

**Approach:**

- Use Temporal's `Workflow.patch` API for additive changes
- Example: Adding new activity call requires version check

**Further Research:**

- Study Temporal's versioning best practices
- Define upgrade path from v0.1 → v0.2 workflows
- Test replay safety with workflow history

---

<!-- anchor: deeper-dive-multi-activity-orchestration -->
#### **2. Multi-Activity Orchestration (Job Chains)**

**Challenge:** How to represent job dependencies in ActiveJob DSL?

**Proposed DSL:**

```ruby
class ReportJob < ApplicationJob
  orchestrates do
    run FetchDataJob
    run TransformDataJob, depends_on: FetchDataJob
    run SendEmailJob, depends_on: TransformDataJob
  end
end
```

**Further Design:**

- Define workflow structure for chains
- Handle partial failures (retry individual steps)
- Support parallel branches (fan-out/fan-in)

---

<!-- anchor: deeper-dive-custom-retry-policies -->
#### **3. Per-Job Retry Policy Customization**

**Challenge:** Allow advanced users to override default retry behavior per job.

**Proposed API:**

```ruby
class CustomRetryJob < ApplicationJob
  temporal_retry_policy(
    initial_interval: 10.seconds,
    backoff_coefficient: 1.5,
    maximum_interval: 5.minutes,
    maximum_attempts: 10,
    non_retryable_error_types: [CustomError]
  )
end
```

**Further Design:**

- Define DSL for retry policy
- Ensure compatibility with existing `retry_on` DSL
- Document precedence (temporal_retry_policy vs retry_on)

---

<!-- anchor: deeper-dive-dead-letter-queue -->
#### **4. Dead Letter Queue (DLQ) & Failure Handling**

**Challenge:** Where do permanently failed jobs go?

**Current Behavior (v0.1):**

- Failed workflows remain in Temporal history (marked "Failed")
- No automatic DLQ or alerting

**Proposed Enhancement (v0.2+):**

- Optional DLQ workflow: failed jobs trigger a separate workflow
- DLQ can retry, send alerts, or log to external system (Sentry, Datadog)

**Further Design:**

- Define DLQ workflow structure
- Integrate with Rails error tracking (Sentry, Bugsnag)
- Support custom DLQ handlers per job class

---

<!-- anchor: deeper-dive-testing-framework -->
#### **5. Testing Framework for Temporal-Backed Jobs**

**Challenge:** How do developers test jobs that use Temporal features (signals, queries, schedules)?

**Current Approach (v0.1):**

- Test job logic in isolation (unit tests for `perform`)
- Integration tests with Temporal test server (slow)

**Proposed Enhancement (v0.2+):**

- Mocking helpers: `ActiveJob::Temporal::TestHelpers`
- Time travel: `Temporal.time_warp(5.minutes)` in tests
- Signal/Query mocks: Stub signals without real Temporal server

**Further Research:**

- Study Temporal Go/Java SDK test frameworks
- Build Ruby-specific test helpers
- Document testing best practices

---

<!-- anchor: glossary -->
## 6. Glossary

**Activity**: A Temporal unit of work that performs side effects (e.g., database writes, API calls). In activejob-temporal, `AjRunnerActivity` executes the job's `perform` method.

**Adapter Pattern**: A design pattern that translates one interface to another. Here, `TemporalAdapter` translates ActiveJob's `enqueue` interface to Temporal's `start_workflow`.

**C4 Model**: A hierarchical diagramming framework (Context, Container, Component, Code) for software architecture.

**Determinism**: Property of workflow code where replaying the same inputs produces the same outputs. Required by Temporal for workflow history replay.

**gRPC**: A high-performance RPC framework used by Temporal for client-server communication.

**GlobalID**: Rails feature that serializes ActiveRecord models as URIs (e.g., `gid://app/User/123`), allowing safe job argument serialization.

**History**: Temporal's event log for a workflow execution, storing all decisions (timers, activity starts, results). Used for replay and debugging.

**Idempotency**: Property where executing an operation multiple times produces the same result as executing it once. Critical for retryable jobs.

**Long Polling**: Technique where workers hold open HTTP connections to Temporal, waiting for tasks. More efficient than frequent short polls.

**Namespace**: Temporal's logical isolation boundary. Workflows in different namespaces cannot interact.

**Orchestration**: Coordination of multiple activities or workflows. Temporal's core purpose is durable orchestration.

**RetryPolicy**: Temporal configuration defining how activities are retried on failure (initial interval, backoff, max attempts).

**Search Attributes**: Indexed metadata attached to workflows, enabling filtering in Temporal UI (e.g., find all workflows for `ajClass:SendInvoiceJob`).

**Signal**: Asynchronous message sent to a running workflow, triggering state changes (not used in v0.1).

**Task Queue**: Named queue where Temporal places workflow/activity tasks. Workers poll specific queues.

**Temporal**: Open-source durable execution platform for orchestrating distributed applications. Provides workflows, activities, timers, retries.

**Workflow**: Deterministic function that coordinates activities, timers, and child workflows. In activejob-temporal, `AjWorkflow` orchestrates job execution.

**Workflow ID**: Unique identifier for a workflow execution. Here, `ajwf:<JobClass>:<job_id>` enables deduplication.

---

## Summary

The activejob-temporal architecture provides a **production-ready bridge** between Rails ActiveJob and Temporal's durable execution platform. By maintaining ActiveJob's familiar API while leveraging Temporal's orchestration engine, it enables Rails developers to build resilient background job systems with minimal code changes.

**Key Strengths:**

- **Zero-friction adoption**: Change one line of config
- **Durable-by-default**: Fault-tolerant scheduling and retries
- **Operational visibility**: Rich search and debugging via Temporal UI
- **Scalable**: Horizontal worker scaling, millions of concurrent jobs

**v0.1 Trade-offs:**

- Single workflow/activity pattern (simple but less flexible)
- No advanced Temporal features (signals, child workflows)
- Requires Temporal cluster (adds operational dependency)

**Evolution Path:**

- v0.2: Schedules, tracing, rate limiting
- v0.3: Signals, queries, multi-activity orchestration
- v1.0: Stable API, migration tooling, production hardening

This blueprint serves as the foundational guide for implementing the gem and evolving it toward a mature, enterprise-grade background job solution.
