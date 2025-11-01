# Worker Setup Guide

This guide covers setting up and running ActiveJob Temporal workers.

## Prerequisites
- Temporal server accessible (e.g., Dockerized Temporal test server listening on `localhost:7233`).
- Ruby 3.2+ environment with the `activejob-temporal` gem and the Temporal Ruby SDK (`temporalio-worker`) installed.
- Optional Rails application: set `RAILS_ROOT` to load your app so job classes are available to the worker.

## Required Environment Variables
Set the following variables before starting the worker:

| Variable | Required | Description | Example |
| --- | --- | --- | --- |
| `TEMPORAL_TARGET` | Yes | Host and port of the Temporal frontend service. | `localhost:7233` |
| `TEMPORAL_NAMESPACE` | Yes | Temporal namespace to poll for workflows. | `default` |
| `AJ_TEMPORAL_WORKER_QUEUE` | Yes | Task queue the worker will poll for jobs. | `default` |
| `AJ_TEMPORAL_MAX_ACT` | No | Maximum concurrent activity executions (defaults to `100`). | `50` |
| `TEMPORAL_MAX_CONCURRENT_ACTIVITIES` | No | Maximum concurrent activities per worker (defaults to `100`). Alternative to `AJ_TEMPORAL_MAX_ACT`. | `200` |
| `TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS` | No | Maximum concurrent workflow tasks per worker (defaults to `100`). | `200` |

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

## Worker Performance Tuning

The worker process can be tuned for high-throughput scenarios by adjusting concurrency settings. These settings control how many activities and workflow tasks can execute concurrently within a single worker process.

### Configuration via ActiveJob::Temporal Config

The recommended approach is to configure these settings in your ActiveJob::Temporal initializer, then pass them to the worker:

```ruby
# config/initializers/activejob_temporal.rb
ActiveJob::Temporal.configure do |config|
  config.target = ENV.fetch('TEMPORAL_TARGET', 'localhost:7233')
  config.namespace = ENV.fetch('TEMPORAL_NAMESPACE', 'default')
  config.max_concurrent_activities = 200      # Default: 100
  config.max_concurrent_workflow_tasks = 200  # Default: 100
end
```

Then in your worker bootstrap script (e.g., `bin/temporal-worker`), pass these values to `Temporalio::Worker.new`:

```ruby
#!/usr/bin/env ruby
# bin/temporal-worker

require_relative '../config/environment'

config = ActiveJob::Temporal.config
client = ActiveJob::Temporal.client

worker = Temporalio::Worker.new(
  client: client,
  task_queue: ENV.fetch('AJ_TEMPORAL_WORKER_QUEUE', 'default'),
  workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
  activities: [ActiveJob::Temporal::Activities::AjRunnerActivity],
  max_concurrent_activity_task_executions: config.max_concurrent_activities,
  max_concurrent_workflow_task_executions: config.max_concurrent_workflow_tasks
)

puts "Starting worker on task queue: #{worker.task_queue}"
puts "Max concurrent activities: #{config.max_concurrent_activities}"
puts "Max concurrent workflow tasks: #{config.max_concurrent_workflow_tasks}"

worker.run
```

### Configuration via Environment Variables

Alternatively, you can set these values via environment variables:

```bash
TEMPORAL_TARGET=localhost:7233 \
TEMPORAL_NAMESPACE=default \
AJ_TEMPORAL_WORKER_QUEUE=default \
TEMPORAL_MAX_CONCURRENT_ACTIVITIES=200 \
TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=200 \
bin/temporal-worker
```

The worker bootstrap script should read these from the configuration:

```ruby
config = ActiveJob::Temporal.config  # Already initialized with ENV vars

worker = Temporalio::Worker.new(
  # ... other options ...
  max_concurrent_activity_task_executions: config.max_concurrent_activities,
  max_concurrent_workflow_task_executions: config.max_concurrent_workflow_tasks
)
```

### Tuning Guidelines

**Default (100)**: Appropriate for most workloads. Each worker can execute up to 100 concurrent activities and 100 concurrent workflow tasks.

**High-throughput (200-500)**: Increase to 200-500 for high-throughput scenarios with sufficient memory. Monitor worker memory usage when increasing. Example:

```bash
TEMPORAL_MAX_CONCURRENT_ACTIVITIES=300 \
TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=300 \
bin/temporal-worker
```

**Resource-constrained (50)**: Decrease for memory-limited workers or CPU-intensive jobs:

```ruby
config.max_concurrent_activities = 50
config.max_concurrent_workflow_tasks = 50
```

**Trade-offs**:
- **Higher concurrency** = More throughput for I/O-bound jobs, but more memory usage
- **Lower concurrency** = Less memory usage, better for CPU-bound or memory-intensive jobs

See the [Configuration Reference](./configuration_reference.md#production-tuning) for detailed guidance on when to adjust these settings, memory/CPU trade-offs, and monitoring recommendations.
