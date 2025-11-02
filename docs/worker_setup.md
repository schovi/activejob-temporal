# Worker Setup Guide

This guide covers setting up and running ActiveJob Temporal workers.

## Prerequisites
- Temporal server accessible (e.g., Dockerized Temporal test server listening on `localhost:7233`).
- Ruby 3.2+ environment with the `activejob-temporal` gem and the Temporal Ruby SDK (`temporalio-worker`) installed.
- Rails application with `activejob-temporal` gem in the Gemfile.

## Required Environment Variables
Set the following variables before starting the worker:

| Variable | Required | Description | Example |
| --- | --- | --- | --- |
| `TEMPORAL_TARGET` | Yes | Host and port of the Temporal frontend service. | `localhost:7233` |
| `TEMPORAL_NAMESPACE` | Yes | Temporal namespace to poll for workflows. | `default` |
| `AJ_TEMPORAL_WORKER_QUEUE` | Yes | Task queue the worker will poll for jobs. | `default` |
| `AJ_TEMPORAL_MAX_ACT` | No | Maximum concurrent activity executions (defaults to `100`). | `50` |
| `AJ_TEMPORAL_MAX_WORKFLOWS` | No | Maximum concurrent workflow task polls (defaults to `5`). | `20` |

## Starting the Worker

1. Ensure the Temporal server is running locally or reachable over the network.
2. From your Rails application directory, run the worker:

```bash
cd /path/to/your/rails/app
TEMPORAL_TARGET=localhost:7233 \
TEMPORAL_NAMESPACE=default \
AJ_TEMPORAL_WORKER_QUEUE=default \
bundle exec temporal-worker
```

The worker automatically detects your Rails environment and loads your job classes.

### Options

- **`AJ_TEMPORAL_WORKER_QUEUE`**: Task queue name. Defaults to `default`.
- **`AJ_TEMPORAL_MAX_ACT`**: Maximum concurrent activity executions. Defaults to `100`.
- **`AJ_TEMPORAL_MAX_WORKFLOWS`**: Maximum concurrent workflow task polls. Defaults to `5`.
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
RAILS_ROOT=/opt/myapp AJ_TEMPORAL_WORKER_QUEUE=high_priority bundle exec temporal-worker &
RAILS_ROOT=/opt/myapp AJ_TEMPORAL_WORKER_QUEUE=default bundle exec temporal-worker &
```

## Expected Log Output
The worker emits structured JSON logs. On startup you should see output similar to:

```json
{"event":"worker_started","task_queue":"default","max_concurrent_activities":100,"max_concurrent_workflows":5,"namespace":"default","target":"localhost:7233","timestamp":"2024-05-01T18:42:13Z"}
```

When the worker shuts down (for example, via `Ctrl+C`), you should see:

```json
{"event":"worker_shutdown","task_queue":"default","timestamp":"2024-05-01T18:45:27Z"}
```

## Stopping the Worker
Press `Ctrl+C` or send `SIGTERM` to the worker process. The Temporal SDK will finish in-flight activities before exiting and will emit the `worker_shutdown` log event.

## Manual Test

With a Temporal server running, run the worker from your Rails app directory:

```bash
cd /path/to/rails/app
TEMPORAL_TARGET=localhost:7233 \
TEMPORAL_NAMESPACE=default \
AJ_TEMPORAL_WORKER_QUEUE=default \
bundle exec temporal-worker
```

You should see:
- Initial `worker_started` event in JSON logs
- Worker blocks while polling the task queue
- Use `Ctrl+C` to gracefully stop
- Worker emits `worker_shutdown` event on exit

## Worker Performance Tuning

The worker process can be tuned for different deployment scenarios by adjusting concurrency settings via environment variables.

### Concurrency Configuration

#### Activity Task Concurrency

Controls how many jobs execute in parallel:

```bash
AJ_TEMPORAL_MAX_ACT=200 bundle exec temporal-worker
```

- **Default:** 100
- **Higher values:** More jobs execute in parallel (higher throughput)
- **Lower values:** Less resource consumption, better for constrained environments
- **Recommended:** 50-200 for typical workloads

#### Workflow Task Concurrency

Controls how many workflows can be orchestrated concurrently:

```bash
AJ_TEMPORAL_MAX_WORKFLOWS=50 bundle exec temporal-worker
```

- **Default:** 5
- **Higher values:** More workflows being orchestrated concurrently
- **Lower values:** Lower CPU overhead, better for resource-constrained environments
- **Typical Range:** 5-100

**Why adjust this?** Workflow tasks are CPU-bound and determine:
- Which activities to schedule
- When activities completed
- Whether to retry or discard
- Durable timer scheduling

Increase if you see high latency between activity completion and next activity scheduled.

#### Combined Configuration

```bash
# Balanced for medium-load scenario
TEMPORAL_TARGET=temporal.example.com:7233 \
TEMPORAL_NAMESPACE=production \
AJ_TEMPORAL_WORKER_QUEUE=important_jobs \
AJ_TEMPORAL_MAX_ACT=150 \
AJ_TEMPORAL_MAX_WORKFLOWS=25 \
bundle exec temporal-worker
```

### Resource Consumption Guidelines

**Low-resource environment** (1 vCPU, 512MB RAM):
```bash
AJ_TEMPORAL_MAX_ACT=10
AJ_TEMPORAL_MAX_WORKFLOWS=2
```

**Standard environment** (2 vCPU, 2GB RAM):
```bash
AJ_TEMPORAL_MAX_ACT=100
AJ_TEMPORAL_MAX_WORKFLOWS=5
```

**High-throughput environment** (8 vCPU, 16GB RAM):
```bash
AJ_TEMPORAL_MAX_ACT=500
AJ_TEMPORAL_MAX_WORKFLOWS=50
```

### Monitoring & Tuning

Use Temporal UI (http://localhost:8080 in development) to monitor:
- **Workflow Task Queue**: Shows queue depth and processing rate
- **Activity Task Queue**: Shows queue depth and processing rate
- **Worker Health**: Shows worker availability and last heartbeat

**Tuning Process:**
1. Deploy with default settings (100 activities, 5 workflows)
2. Monitor queue depths in Temporal UI
3. If Workflow Task Queue is growing: increase `AJ_TEMPORAL_MAX_WORKFLOWS`
4. If Activity Task Queue is growing: increase `AJ_TEMPORAL_MAX_ACT`
5. Monitor CPU/Memory usage after each adjustment
6. Iterate until balanced

### Deployment Scenarios

#### Docker Compose (Development)
```yaml
# In compose file
environment:
  AJ_TEMPORAL_MAX_ACT: 20
  AJ_TEMPORAL_MAX_WORKFLOWS: 3
```

#### Kubernetes (Production)
```yaml
spec:
  containers:
  - name: temporal-worker
    env:
    - name: AJ_TEMPORAL_MAX_ACT
      value: "300"
    - name: AJ_TEMPORAL_MAX_WORKFLOWS
      value: "50"
    resources:
      requests:
        memory: "256Mi"
        cpu: "500m"
      limits:
        memory: "1Gi"
        cpu: "2000m"
```

#### EC2/VPS (Self-hosted)
```bash
#!/bin/bash
# /etc/systemd/system/temporal-worker.service

[Service]
Environment="TEMPORAL_TARGET=temporal.prod.internal:7233"
Environment="TEMPORAL_NAMESPACE=production"
Environment="AJ_TEMPORAL_WORKER_QUEUE=default"
Environment="AJ_TEMPORAL_MAX_ACT=200"
Environment="AJ_TEMPORAL_MAX_WORKFLOWS=20"
ExecStart=/usr/local/bin/temporal-worker
```
