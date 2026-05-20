# Worker Setup Guide

This guide covers setting up and running ActiveJob Temporal workers.

## Prerequisites
- Temporal server accessible (e.g., Dockerized Temporal test server listening on `localhost:7233`).
- Ruby 4.0+ environment with the `activejob-temporal` gem and the Temporal Ruby SDK (`temporalio-worker`) installed.
- Rails application with `activejob-temporal` gem in the Gemfile.

## Required Environment Variables
Set the following variables before starting the worker:

| Variable | Required | Description | Example |
| --- | --- | --- | --- |
| `ACTIVEJOB_TEMPORAL_TARGET` | Yes | Host and port of the Temporal frontend service. | `localhost:7233` |
| `ACTIVEJOB_TEMPORAL_NAMESPACE` | Yes | Temporal namespace to poll for workflows. | `default` |
| `ACTIVEJOB_TEMPORAL_TASK_QUEUE` | Yes | Task queue the worker will poll for jobs. | `default` |
| `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES` | No | Maximum activity task poll capacity (defaults to `100`). | `50` |
| `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS` | No | Maximum workflow task poll capacity (defaults to `5`). | `20` |
| `ACTIVEJOB_TEMPORAL_HEALTH_CHECK_PORT` | No | Expose `GET /health` on the given port. Off by default. | `8080` |
| `ACTIVEJOB_TEMPORAL_HEALTH_CHECK_BIND` | No | Bind address for the health endpoint. Defaults to localhost. | `0.0.0.0` |
| `ACTIVEJOB_TEMPORAL_METRICS_PROVIDER` | No | Metrics provider. Set to `prometheus` to collect built-in metrics. | `prometheus` |
| `ACTIVEJOB_TEMPORAL_METRICS_PORT` | No | Expose Prometheus metrics at `GET /metrics`. Off by default. | `9394` |
| `ACTIVEJOB_TEMPORAL_METRICS_BIND` | No | Bind address for the metrics endpoint. Defaults to localhost. | `0.0.0.0` |

## Starting the Worker

1. Ensure the Temporal server is running locally or reachable over the network.
2. From your Rails application directory, run the worker:

```bash
cd /path/to/your/rails/app
ACTIVEJOB_TEMPORAL_TARGET=localhost:7233 \
ACTIVEJOB_TEMPORAL_NAMESPACE=default \
ACTIVEJOB_TEMPORAL_TASK_QUEUE=default \
bundle exec temporal-worker
```

The worker automatically detects your Rails environment and loads your job classes.

### Options

- **`ACTIVEJOB_TEMPORAL_TASK_QUEUE`**: Task queue name. Defaults to `default`.
- **`ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES`**: Maximum activity task poll capacity. Defaults to `100`.
- **`ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS`**: Maximum workflow task poll capacity. Defaults to `5`.
- **`--health-check-port PORT`**: Optional HTTP health endpoint at `GET /health`. Can also be set with `ACTIVEJOB_TEMPORAL_HEALTH_CHECK_PORT`.
- **`--health-check-bind HOST`**: Health endpoint bind address. Defaults to `127.0.0.1`; set `0.0.0.0` when an orchestrator must reach the port from outside the process namespace.
- **`--metrics-port PORT`**: Optional Prometheus metrics endpoint at `GET /metrics`. Can also be set with `ACTIVEJOB_TEMPORAL_METRICS_PORT`.
- **`--metrics-bind HOST`**: Metrics endpoint bind address. Defaults to `127.0.0.1`; set `0.0.0.0` when Prometheus scrapes from outside the process namespace.
- **`RAILS_ROOT`**: Optional path to Rails app. Auto-detected if omitted (uses current directory).

### Examples

**From app directory (auto-detected):**
```bash
bundle exec temporal-worker
```

**Explicit Rails app path:**
```bash
RAILS_ROOT=/opt/myapp bundle exec temporal-worker
```

**Multiple workers on different queues:**
```bash
RAILS_ROOT=/opt/myapp ACTIVEJOB_TEMPORAL_TASK_QUEUE=high_priority bundle exec temporal-worker &
RAILS_ROOT=/opt/myapp ACTIVEJOB_TEMPORAL_TASK_QUEUE=default bundle exec temporal-worker &
```

**Worker health endpoint for local checks:**
```bash
bundle exec temporal-worker --health-check-port 8080
curl http://localhost:8080/health
```

**Worker health endpoint for container probes:**
```bash
bundle exec temporal-worker --health-check-bind 0.0.0.0 --health-check-port 8080
```

**Prometheus metrics endpoint:**
```bash
bundle exec temporal-worker --metrics-bind 0.0.0.0 --metrics-port 9394
curl http://localhost:9394/metrics
```

The metrics endpoint returns Prometheus text format from `GET /metrics`. It is not a health probe.

The health endpoint returns `200` after the worker marks itself running. If queried before startup completes, it returns `503`; during process shutdown the listener is closed. The JSON payload includes the task queue, namespace, Temporal target, active activity task count, last activity task start time, poll capacity settings, PID, start time, and uptime:

```json
{
  "status": "ok",
  "worker_running": true,
  "started_at": "2026-05-20T18:30:00Z",
  "last_poll": "2026-05-20T18:30:15Z",
  "active_tasks": 2,
  "uptime_seconds": 42,
  "task_queue": "default",
  "namespace": "default",
  "target": "localhost:7233",
  "max_concurrent_activities": 100,
  "max_concurrent_workflows": 5,
  "pid": 12345
}
```

`last_poll` tracks the last activity task started by this worker process, not a raw Temporal SDK long-poll cycle. `active_tasks` tracks active activity attempts currently executing in the worker process.

## Expected Log Output
The worker emits structured JSON logs. On startup you should see output similar to:

```json
{"event":"worker_started","task_queue":"default","max_concurrent_activities":100,"max_concurrent_workflows":5,"namespace":"default","target":"localhost:7233","timestamp":"2024-05-01T18:42:13Z"}
```

When the worker shuts down (for example, via `Ctrl+C`), you should see:

```json
{"event":"worker_shutdown","task_queue":"default","timestamp":"2024-05-01T18:45:27Z"}
```

When metrics are enabled, startup also logs `metrics_server_started` with the bind address and assigned port.

## Stopping the Worker
Press `Ctrl+C` or send `SIGTERM` to the worker process. The Temporal SDK will finish in-flight activities before exiting and will emit the `worker_shutdown` log event.

## Manual Test

With a Temporal server running, run the worker from your Rails app directory:

```bash
cd /path/to/rails/app
ACTIVEJOB_TEMPORAL_TARGET=localhost:7233 \
ACTIVEJOB_TEMPORAL_NAMESPACE=default \
ACTIVEJOB_TEMPORAL_TASK_QUEUE=default \
bundle exec temporal-worker
```

You should see:
- Initial `worker_started` event in JSON logs
- Worker blocks while polling the task queue
- Use `Ctrl+C` to gracefully stop
- Worker emits `worker_shutdown` event on exit

## Worker Performance Tuning

The worker process can be tuned for different deployment scenarios by adjusting poll settings via environment variables. Use this section for startup mechanics. Use the [Performance Tuning Guide](performance_tuning.md) for workload-specific recommendations, payload benchmarking, database pooling, and monitoring.

### Concurrency Configuration

#### Activity Task Concurrency

Controls activity task polling capacity for the worker process:

```bash
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=200 bundle exec temporal-worker
```

- **Default:** 100
- **Higher values:** More activity poll capacity when jobs and dependencies have headroom
- **Lower values:** Less resource consumption, better for constrained environments
- **Recommended:** 50-200 for typical workloads

#### Workflow Task Concurrency

Controls workflow task polling capacity for the worker process:

```bash
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=50 bundle exec temporal-worker
```

- **Default:** 5
- **Higher values:** More workflow orchestration capacity
- **Lower values:** Lower CPU overhead, better for resource-constrained environments
- **Typical Range:** 5-50

**Why adjust this?** Workflow tasks are CPU-bound and determine:
- Which activities to schedule
- When activities completed
- Whether to retry or discard
- Durable timer scheduling

Increase if you see high latency between activity completion and next activity scheduled.

#### Combined Configuration

```bash
# Balanced for medium-load scenario
ACTIVEJOB_TEMPORAL_TARGET=temporal.example.com:7233 \
ACTIVEJOB_TEMPORAL_NAMESPACE=production \
ACTIVEJOB_TEMPORAL_TASK_QUEUE=important_jobs \
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=150 \
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=25 \
bundle exec temporal-worker
```

### Resource Consumption Guidelines

**Low-resource environment** (1 vCPU, 512MB RAM):
```bash
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=10
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=2
```

**Standard environment** (2 vCPU, 2GB RAM):
```bash
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=100
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=5
```

**High-throughput environment** (8 vCPU, 16GB RAM):
```bash
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=500
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=50
```

### Monitoring & Tuning

Use Temporal UI (http://localhost:8080 in development) to monitor:
- **Workflow Task Queue**: Shows queue depth and processing rate
- **Activity Task Queue**: Shows queue depth and processing rate
- **Worker Health**: Shows worker availability and last heartbeat

**Tuning Process:**
1. Deploy with default settings (100 activity polls, 5 workflow task polls)
2. Monitor queue depths in Temporal UI
3. If Workflow Task Queue is growing: increase `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS`
4. If Activity Task Queue is growing: increase `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES`
5. Monitor CPU/Memory usage after each adjustment
6. Iterate until balanced

For a full tuning checklist, scenario-specific starting points, payload benchmarks, and database pool guidance, see the [Performance Tuning Guide](performance_tuning.md).

### Deployment Scenarios

#### Docker Compose (Development)
```yaml
# In compose file
environment:
  ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES: 20
  ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS: 3
```

#### Kubernetes (Production)
```yaml
spec:
  containers:
  - name: temporal-worker
    args: ["--health-check-bind", "0.0.0.0", "--health-check-port", "8080"]
    env:
    - name: ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES
      value: "300"
    - name: ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS
      value: "50"
    ports:
    - name: health
      containerPort: 8080
    readinessProbe:
      httpGet:
        path: /health
        port: health
    livenessProbe:
      httpGet:
        path: /health
        port: health
    resources:
      requests:
        memory: "256Mi"
        cpu: "500m"
      limits:
        memory: "1Gi"
        cpu: "2000m"
```

#### EC2/VPS (Systemd)

Use the [systemd worker examples](../examples/systemd/) for VM or bare-metal deployments. The examples include a single worker service, a template unit for one worker per task queue, restart policy, file logging, log rotation, and SELinux notes.

```bash
sudo install -D -m 0644 examples/systemd/temporal-worker.service /etc/systemd/system/temporal-worker.service
sudo systemctl daemon-reload
sudo systemctl enable --now temporal-worker
```
