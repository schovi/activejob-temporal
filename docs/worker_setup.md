# Temporal Worker Setup

## Prerequisites
- Temporal server accessible (e.g., Dockerized Temporal test server listening on `localhost:7233`).
- Ruby environment with the `activejob-temporal` gem and the Temporal Ruby SDK (`temporalio-worker`) installed.
- Optional Rails application: set `RAILS_ROOT` to load your app so job classes are available to the worker.

## Required Environment Variables
Set the following variables before starting the worker:

| Variable | Required | Description | Example |
| --- | --- | --- | --- |
| `TEMPORAL_TARGET` | Yes | Host and port of the Temporal frontend service. | `localhost:7233` |
| `TEMPORAL_NAMESPACE` | Yes | Temporal namespace to poll for workflows. | `default` |
| `AJ_TEMPORAL_WORKER_QUEUE` | Yes | Task queue the worker will poll for jobs. | `default` |
| `AJ_TEMPORAL_MAX_ACT` | No | Maximum concurrent activity executions (defaults to `100`). | `50` |

## Starting the Worker
1. Ensure the Temporal server is running locally or reachable over the network.
2. From the project root, export the environment variables and launch the worker:

```bash
TEMPORAL_TARGET=localhost:7233 \
TEMPORAL_NAMESPACE=default \
AJ_TEMPORAL_WORKER_QUEUE=default \
bin/temporal-worker
```

Add `AJ_TEMPORAL_MAX_ACT=50` (or another value) if you need to tune activity concurrency. When running inside a Rails app, also export `RAILS_ROOT=/path/to/your/app`.

## Expected Log Output
The worker emits structured JSON logs. On startup you should see output similar to:

```json
{"event":"worker_started","task_queue":"default","max_concurrent_activities":100,"namespace":"default","target":"localhost:7233","timestamp":"2024-05-01T18:42:13Z"}
```

When the worker shuts down (for example, via `Ctrl+C`), you should see:

```json
{"event":"worker_shutdown","task_queue":"default","timestamp":"2024-05-01T18:45:27Z"}
```

## Stopping the Worker
Press `Ctrl+C` or send `SIGTERM` to the worker process. The Temporal SDK will finish in-flight activities before exiting and will emit the `worker_shutdown` log event.

## Manual Test
With a Temporal test server running locally, execute:

```bash
TEMPORAL_TARGET=localhost:7233 \
TEMPORAL_NAMESPACE=default \
AJ_TEMPORAL_WORKER_QUEUE=default \
bin/temporal-worker
```

The worker should connect without errors, log the `worker_started` event, and block while polling the task queue. Use `Ctrl+C` to stop the worker and verify the `worker_shutdown` log is emitted.
