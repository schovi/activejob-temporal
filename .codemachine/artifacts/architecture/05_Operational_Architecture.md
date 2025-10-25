# System Architecture Blueprint: activejob-temporal

**Version:** 1.0
**Date:** 2025-10-25

---

<!-- anchor: operational-architecture -->
## 3. Operational Architecture

<!-- anchor: cross-cutting-concerns -->
### 3.8. Cross-Cutting Concerns

<!-- anchor: authentication-authorization -->
#### **3.8.1. Authentication & Authorization**

**Application-Level (Job Execution)**

- **No Built-In Auth**: The gem does not enforce authentication/authorization for job execution
- **App Responsibility**: Job classes (`SendInvoiceJob.perform`) must perform their own authorization checks
  - Example: Check if user has permission to send invoice before executing business logic
- **GlobalID Context**: Jobs receive ActiveRecord model IDs (via GlobalID); can load models and check permissions

**Temporal Cluster Access**

- **mTLS Support**: Temporal client supports mutual TLS for secure cluster connections
  - Configure via `Temporalio::Client.connect` with `tls_config` parameter
  - Requires certificates (CA, client cert, client key)
- **Namespace Isolation**: Each Temporal namespace is logically isolated; recommend separate namespaces per environment (dev, staging, production)
- **API Keys (Temporal Cloud)**: If using Temporal Cloud, configure API key via SDK options

**Worker Authorization**

- **Task Queue Isolation**: Workers only poll queues they're configured for
  - Example: "billing" worker only processes billing jobs
  - Prevents cross-queue job execution
- **No Dynamic Queue Switching (v0.1)**: Workers are statically configured with one task queue

**Recommendation**: Use Temporal's namespace-level access control + mTLS for production deployments.

---

<!-- anchor: logging-monitoring -->
#### **3.8.2. Logging & Monitoring**

<!-- anchor: logging-strategy -->
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

---

<!-- anchor: monitoring-strategy -->
##### **Monitoring Strategy**

**Temporal Built-In Metrics (v0.1)**

The Temporal cluster exposes Prometheus metrics for workflows/activities:

- **Workflow Metrics**: `workflow_started`, `workflow_completed`, `workflow_failed`, `workflow_cancelled`
- **Activity Metrics**: `activity_execution_latency`, `activity_execution_failed`, `activity_task_schedule_to_start_latency`
- **Task Queue Metrics**: `task_queue_depth`, `task_queue_backlog`

**Access**: Available in Temporal UI (Metrics tab) or scrape Prometheus endpoint from Temporal server.

**Application-Level Metrics (Future: v0.2+)**

Custom metrics to emit from the gem:

| Metric | Type | Labels | Purpose |
|--------|------|--------|---------|
| `aj_temporal_enqueue_total` | Counter | `job_class`, `queue`, `status` (success/failure) | Track enqueue rate |
| `aj_temporal_enqueue_duration_seconds` | Histogram | `job_class` | Measure enqueue latency (Rails → Temporal) |
| `aj_temporal_activity_duration_seconds` | Histogram | `job_class`, `status` (success/failure) | Measure job execution time |
| `aj_temporal_payload_size_bytes` | Histogram | `job_class` | Track payload sizes |

**Future Integration**: StatsD or Prometheus client for custom metrics.

---

<!-- anchor: observability-tools -->
##### **Observability Tools**

**Temporal Web UI**

- **Search Workflows**: Query by Search Attributes (`ajClass`, `ajQueue`, `ajJobId`, `ajEnqueuedAt`)
- **Inspect History**: View workflow execution events, activity retries, timers
- **Stack Traces**: See exact code paths for failed activities
- **Cancellation Status**: Confirm if workflows were cancelled

**OpenTelemetry Tracing (Optional)**

If `enable_tracing: true`:

- **Spans Created**:
  - `AjWorkflow.execute` (parent span)
  - `AjRunnerActivity.execute` (child span)
- **Span Attributes**:
  - `workflow_id`, `run_id`, `task_queue`, `job_class`, `job_id`, `queue`
- **Propagation**: Context propagated from enqueue → workflow → activity
- **Backend**: Export to Jaeger, Zipkin, or Datadog APM

**Example Trace:**

```
Trace ID: abc123
├─ Span: enqueue (Rails)                   [duration: 50ms]
├─ Span: AjWorkflow.execute                [duration: 5min 2s]
│  ├─ Span: Workflow.sleep                 [duration: 5min]
│  └─ Span: AjRunnerActivity.execute       [duration: 2s]
│     └─ Span: SendInvoiceJob.perform      [duration: 1.8s]
│        └─ Span: HTTP POST /invoices/send [duration: 1.5s]
```

---

<!-- anchor: security-considerations -->
#### **3.8.3. Security Considerations**

<!-- anchor: security-payload -->
##### **Payload Security**

**1. Safe Serialization**

- **Allowed Types**: Only `ActiveJob::Arguments`-compatible types (primitives, hashes, arrays, GlobalID)
- **Disallowed**: Ruby objects, Procs, Threads, File handles
- **Enforcement**: Serialization raises `ActiveJob::SerializationError` if unsupported type is passed

**2. Payload Size Limits**

- **Default Limit**: 250KB per job payload
- **Rationale**: Prevent DoS attacks via large payloads; respect Temporal's 2MB history limit
- **Enforcement**: Check payload size after serialization, raise `SerializationError` if exceeded

**3. Sensitive Data Handling**

- **Do Not Serialize Secrets**: Never pass API keys, passwords, tokens as job arguments
- **Use GlobalID for Models**: Pass ActiveRecord IDs, not full objects (reduces PII exposure)
- **Redact Logs**: Do not log raw job arguments (may contain sensitive data)

**4. Payload Encryption (Future Enhancement)**

- **v0.1**: No built-in encryption
- **v0.2+**: Optional encryption codec for workflow/activity payloads (Temporal SDK feature)

---

<!-- anchor: security-network -->
##### **Network Security**

**1. TLS Encryption**

- **Client ↔ Temporal**: Use `tls_config` in `Temporalio::Client.connect` for mTLS
- **Worker ↔ Temporal**: Same TLS config for worker connections
- **Recommendation**: Always enable TLS in production

**2. Namespace Isolation**

- **Separate Namespaces**: Use different Temporal namespaces per environment (dev, staging, prod)
- **Access Control**: Configure Temporal server RBAC (if using Temporal Cloud or self-hosted with auth)

**3. Firewall Rules**

- **Temporal Port**: Restrict access to Temporal gRPC port (default 7233) to worker IPs only
- **No Public Exposure**: Temporal cluster should not be internet-accessible

---

<!-- anchor: security-code -->
##### **Code Security**

**1. Dependency Scanning**

- **Automated Scans**: Use `bundler-audit` or `dependabot` to detect vulnerable gems
- **Temporal SDK**: Monitor `temporalio/sdk-ruby` security advisories

**2. Secrets Management**

- **Configuration**: Do not hardcode Temporal target/credentials; use environment variables
- **Rails Credentials**: Store Temporal Cloud API keys in `config/credentials.yml.enc`

**3. Idempotency Keys**

- **Exposure**: `Thread.current[:aj_temporal_idempotency_key]` is available to job code
- **Best Practice**: Use this key for external API idempotency headers (e.g., `Idempotency-Key: <key>` in HTTP requests)
- **Security**: Key is workflow-scoped, safe to use as unique identifier

---

<!-- anchor: scalability-performance -->
#### **3.8.4. Scalability & Performance**

<!-- anchor: scalability-horizontal -->
##### **Horizontal Scalability**

**Worker Scaling**

- **Stateless Workers**: Workers share no state; can scale horizontally by adding processes
- **Task Queue Model**: Multiple workers poll the same task queue; Temporal load-balances tasks
- **Scaling Triggers**:
  - High task queue depth (backlog of pending workflows/activities)
  - Increased job enqueue rate
  - Long-running jobs causing worker saturation

**Example Kubernetes Deployment:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: activejob-temporal-worker
spec:
  replicas: 5  # Scale to 5 workers
  template:
    spec:
      containers:
      - name: worker
        image: myapp:latest
        command: ["bin/temporal-worker"]
        env:
        - name: AJ_TEMPORAL_WORKER_QUEUE
          value: "billing"
        - name: AJ_TEMPORAL_MAX_ACT
          value: "100"
```

**Auto-Scaling**: Use Horizontal Pod Autoscaler (HPA) based on Temporal task queue metrics (requires Prometheus scraping).

---

<!-- anchor: scalability-partitioning -->
##### **Task Queue Partitioning**

**Why Partition?**

- **Isolation**: Prevent high-volume queues from starving low-volume queues
- **Priority**: Run critical jobs on dedicated workers with higher resources
- **Failure Isolation**: Bugs in one queue don't affect others

**Strategy:**

- **Per-Queue Workers**: Deploy separate worker pools per ActiveJob queue
  - Example: `billing` queue → 5 workers, `reports` queue → 2 workers
- **Task Queue Prefix**: Use `task_queue_prefix` config to namespace queues per environment
  - Example: `prod-billing`, `staging-billing`

**Configuration:**

```ruby
# Worker 1: Handles "billing" queue
worker = Temporalio::Worker.new(
  client: client,
  task_queue: "prod-billing",
  workflows: [AjWorkflow],
  activities: [AjRunnerActivity],
  max_concurrent_activity_task_executions: 100
)

# Worker 2: Handles "reports" queue
worker = Temporalio::Worker.new(
  client: client,
  task_queue: "prod-reports",
  workflows: [AjWorkflow],
  activities: [AjRunnerActivity],
  max_concurrent_activity_task_executions: 50
)
```

---

<!-- anchor: performance-optimization -->
##### **Performance Optimization**

**1. Client Connection Pooling**

- **Memoization**: Temporal client is created once per process (singleton pattern)
- **gRPC Channels**: Reused across enqueue calls (no connection overhead per job)

**2. Non-Blocking Scheduled Jobs**

- **Workflow.sleep**: Does not consume worker threads; workers process other tasks during sleep
- **Impact**: Can schedule millions of jobs without thread pool exhaustion

**3. Activity Concurrency**

- **Default**: 100 concurrent activity tasks per worker
- **Tuning**: Adjust `max_concurrent_activity_task_executions` based on:
  - CPU cores (e.g., 2x cores for I/O-bound jobs)
  - Memory limits (each activity may allocate memory)
  - External API rate limits

**4. Payload Size Optimization**

- **Use GlobalID**: Pass ActiveRecord model IDs, not full serialized objects
- **Lazy Loading**: Load associations inside `perform`, not before enqueue
- **External Storage**: For large data (files, reports), upload to S3 and pass URL as job argument

**5. Batching (Future: v0.2+)**

- **Current**: One job = one workflow + one activity
- **Future**: Introduce batch workflow that executes multiple activities (e.g., bulk email sends)

---

<!-- anchor: reliability-availability -->
#### **3.8.5. Reliability & Availability**

<!-- anchor: reliability-fault-tolerance -->
##### **Fault Tolerance**

**Workflow Durability**

- **Automatic Recovery**: If worker crashes during workflow execution, Temporal reschedules on another worker
- **State Persistence**: Workflow history is persisted after each event (sleep, activity start, etc.)
- **No Lost Jobs**: Even if all workers are down, jobs are safely queued in Temporal

**Activity Retries**

- **Configurable Retry Policy**: Map from `retry_on` declarations
- **Exponential Backoff**: Prevents thundering herd on downstream services
- **Max Attempts**: Jobs eventually fail after configured attempts (prevents infinite loops)

**Idempotency**

- **Workflow ID Deduplication**: Prevents duplicate workflow starts (`:reject` policy)
- **Activity Idempotency**: Jobs must be idempotent; gem provides idempotency keys for external API calls

---

<!-- anchor: reliability-failure-modes -->
##### **Failure Modes & Recovery**

| Failure Scenario | Impact | Recovery |
|------------------|--------|----------|
| **Rails Process Crash (Enqueue)** | Job not enqueued | Rails retries enqueue (if using retryable enqueue pattern) |
| **Temporal Cluster Down (Enqueue)** | `EnqueueError` raised | Rails handles error; job not enqueued; retry later |
| **Worker Crash (Workflow)** | Workflow paused | Temporal reschedules workflow task on another worker |
| **Worker Crash (Activity)** | Activity paused | Temporal reschedules activity task; retries per `RetryPolicy` |
| **Database Down (Job Logic)** | Activity fails | Retried per `retry_on` policy (if DB error is retryable) |
| **External API Timeout (Job Logic)** | Activity fails | Retried per `retry_on` policy; eventually fails if max attempts reached |
| **Temporal Cluster Partition** | Workers cannot poll tasks | Tasks queue up; processed when partition heals |

**Recommendation**: Monitor Temporal cluster health; set up alerting for workflow failures.

---

<!-- anchor: reliability-high-availability -->
##### **High Availability**

**Temporal Cluster HA**

- **Production Setup**: Deploy Temporal with multiple frontend/history/matching nodes
- **Database HA**: Use PostgreSQL with replication or managed service (AWS RDS Multi-AZ)
- **Load Balancing**: gRPC-aware load balancer (e.g., Envoy, Nginx) for Temporal frontend

**Worker HA**

- **Multiple Workers**: Run at least 3 workers per queue (withstands 1-2 failures)
- **Health Checks**: Implement liveness probe (check if worker process is running)
- **Graceful Shutdown**: Workers handle SIGTERM gracefully (finish in-flight activities before exit)

**Rails App HA**

- **Stateless Enqueue**: Any Rails instance can enqueue jobs (no leader election needed)
- **Database Transactions**: Use `enqueue_after_transaction_commit? => true` to avoid enqueuing jobs from rolled-back transactions

---

<!-- anchor: deployment-view -->
### 3.9. Deployment View

<!-- anchor: deployment-target-environment -->
#### **Target Environment**

**Supported Platforms:**

- **AWS**: ECS (Fargate or EC2), EKS (Kubernetes), EC2 instances with systemd
- **GCP**: GKE (Kubernetes), Compute Engine
- **Azure**: AKS (Kubernetes), Virtual Machines
- **On-Premise**: Bare metal or VMs with systemd/Docker

**Temporal Cluster Options:**

- **Temporal Cloud**: Managed service (recommended for production)
- **Self-Hosted**: Requires PostgreSQL/Cassandra, multiple Temporal services (frontend, history, matching, worker)
- **Local Dev**: Single-node Temporal server via Docker Compose

---

<!-- anchor: deployment-strategy -->
#### **Deployment Strategy**

<!-- anchor: deployment-components -->
##### **Deployment Components**

**1. Rails Application**

- **Role**: Enqueues jobs via `perform_later`
- **Deployment**: Standard Rails deployment (Puma/Unicorn behind load balancer)
- **Dependencies**: Requires network access to Temporal cluster (gRPC port 7233)
- **No Worker Code**: Does not run Temporal workflows/activities

**2. Temporal Worker Process**

- **Role**: Polls task queues, executes workflows/activities
- **Deployment**: Separate process/container from Rails web servers
- **Entry Point**: `bin/temporal-worker` script
- **Dependencies**: Same codebase as Rails app (shares job class definitions)
- **Scaling**: Horizontal; multiple workers per queue

**3. Temporal Cluster**

- **Role**: Orchestration engine, history storage, task queues
- **Deployment**: External service (Temporal Cloud or self-hosted)
- **Managed By**: Platform team (not application developers)

---

<!-- anchor: deployment-docker -->
##### **Deployment Architecture (Docker + Kubernetes)**

**Diagram:**

~~~plantuml
@startuml
!include https://raw.githubusercontent.com/plantuml-stdlib/C4-PlantUML/master/C4_Deployment.puml

LAYOUT_WITH_LEGEND()

title Deployment Diagram - activejob-temporal on Kubernetes (AWS EKS)

Deployment_Node(aws, "AWS Cloud", "Amazon Web Services") {
  Deployment_Node(eks, "EKS Cluster", "Kubernetes") {
    Deployment_Node(namespace, "Namespace: production", "Kubernetes Namespace") {

      Deployment_Node(rails_deployment, "Rails Web Deployment", "Kubernetes Deployment") {
        Container(rails_pod1, "Rails Pod 1", "Docker Container", "Rails app (Puma)")
        Container(rails_pod2, "Rails Pod 2", "Docker Container", "Rails app (Puma)")
      }

      Deployment_Node(worker_deployment, "Worker Deployment", "Kubernetes Deployment") {
        Container(worker_pod1, "Worker Pod 1", "Docker Container", "bin/temporal-worker (billing queue)")
        Container(worker_pod2, "Worker Pod 2", "Docker Container", "bin/temporal-worker (billing queue)")
      }

      Deployment_Node(service, "Load Balancer", "Kubernetes Service (LoadBalancer)") {
        Container(lb, "AWS ALB", "AWS Elastic Load Balancer")
      }
    }
  }

  Deployment_Node(temporal_cloud, "Temporal Cloud", "SaaS") {
    Container(temporal, "Temporal Cluster", "Managed Service", "Workflows, History, Task Queues")
  }

  Deployment_Node(rds, "AWS RDS", "Managed Database") {
    ContainerDb(postgres, "PostgreSQL", "AWS RDS Multi-AZ", "Rails application data")
  }
}

Deployment_Node(external, "External Services", "Internet") {
  System_Ext(apis, "Payment Gateway, Email Service", "Third-party APIs")
}

Rel(lb, rails_pod1, "Routes HTTP requests", "HTTPS")
Rel(lb, rails_pod2, "Routes HTTP requests", "HTTPS")

Rel(rails_pod1, temporal, "Enqueue jobs", "gRPC (TLS)")
Rel(rails_pod2, temporal, "Enqueue jobs", "gRPC (TLS)")

Rel(worker_pod1, temporal, "Poll task queue", "gRPC long-poll (TLS)")
Rel(worker_pod2, temporal, "Poll task queue", "gRPC long-poll (TLS)")

Rel(rails_pod1, postgres, "Read/Write models", "PostgreSQL wire protocol")
Rel(worker_pod1, postgres, "Read/Write models", "PostgreSQL wire protocol")

Rel(worker_pod1, apis, "Call external APIs", "HTTPS")

@enduml
~~~

**Key Components:**

- **Rails Pods**: Handle HTTP requests, enqueue jobs via Temporal client
- **Worker Pods**: Separate deployment, polls Temporal, executes jobs
- **Temporal Cloud**: External SaaS (or self-hosted cluster in separate VPC)
- **PostgreSQL (RDS)**: Rails application database (not used by Temporal for job state)
- **Load Balancer**: AWS ALB routes traffic to Rails pods

---

<!-- anchor: deployment-configuration -->
##### **Deployment Configuration**

**Environment Variables (12-Factor App):**

```bash
# Temporal Connection
TEMPORAL_TARGET=prod.us-west-2.temporal.io:7233
TEMPORAL_NAMESPACE=production
TEMPORAL_TLS_CERT=/etc/secrets/temporal-client.crt
TEMPORAL_TLS_KEY=/etc/secrets/temporal-client.key

# Worker Configuration
AJ_TEMPORAL_WORKER_QUEUE=billing
AJ_TEMPORAL_MAX_ACT=100
AJ_TEMPORAL_PREFIX=prod-

# Application
RAILS_ENV=production
DATABASE_URL=postgresql://...
```

**Kubernetes Manifests (Example):**

```yaml
# worker-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: temporal-worker-billing
spec:
  replicas: 3
  selector:
    matchLabels:
      app: temporal-worker
      queue: billing
  template:
    metadata:
      labels:
        app: temporal-worker
        queue: billing
    spec:
      containers:
      - name: worker
        image: myapp:v1.2.3
        command: ["bin/temporal-worker"]
        env:
        - name: TEMPORAL_TARGET
          value: "prod.us-west-2.temporal.io:7233"
        - name: AJ_TEMPORAL_WORKER_QUEUE
          value: "prod-billing"
        - name: AJ_TEMPORAL_MAX_ACT
          value: "100"
        volumeMounts:
        - name: temporal-certs
          mountPath: /etc/secrets
          readOnly: true
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
      volumes:
      - name: temporal-certs
        secret:
          secretName: temporal-tls
```

---

<!-- anchor: deployment-health-checks -->
##### **Health Checks & Graceful Shutdown**

**Worker Health Check:**

```ruby
# bin/temporal-worker
worker = Temporalio::Worker.new(
  client: client,
  task_queue: ENV.fetch("AJ_TEMPORAL_WORKER_QUEUE"),
  workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
  activities: [ActiveJob::Temporal::Activities::AjRunnerActivity],
  shutdown_signals: %w[SIGINT SIGTERM]
)

# Blocks until SIGTERM received
worker.run

# Worker gracefully finishes in-flight activities, then exits
```

**Kubernetes Liveness Probe:**

```yaml
livenessProbe:
  exec:
    command: ["pgrep", "-f", "temporal-worker"]
  initialDelaySeconds: 10
  periodSeconds: 30
```

**Shutdown Sequence:**

1. Kubernetes sends SIGTERM to pod
2. Worker receives signal, stops polling new tasks
3. Worker finishes executing current activities (up to `terminationGracePeriodSeconds`)
4. Worker exits with code 0
5. Kubernetes removes pod

**Recommendation**: Set `terminationGracePeriodSeconds: 300` (5 minutes) to allow long-running activities to complete.

---

<!-- anchor: deployment-zero-downtime -->
##### **Zero-Downtime Deployments**

**Strategy:**

1. **Deploy New Workers First**: Start new worker pods with updated code
2. **Wait for Health**: Ensure new workers are polling tasks
3. **Drain Old Workers**: Send SIGTERM to old workers (they finish in-flight jobs)
4. **Terminate Old Workers**: Remove old pods after graceful shutdown

**Workflow Version Compatibility (Future):**

- **v0.1**: No explicit versioning; all workers must run same gem version during deployment
- **v0.2+**: Use Temporal's workflow versioning (Workflow.patch) for safe gradual rollouts

**Database Migrations:**

- **ActiveRecord Migrations**: Run before deploying new code (as usual)
- **Temporal Schema**: No migrations needed (Temporal manages its own schema)
