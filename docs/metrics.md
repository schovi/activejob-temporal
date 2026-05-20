# Metrics Guide

`ActiveJob::Temporal` can record Prometheus metrics in any process that loads the gem. Metrics are disabled by default. The worker CLI can expose worker-process metrics at `GET /metrics`.

## Enable Metrics

Configure Prometheus metrics in the Rails initializer:

```ruby
ActiveJob::Temporal.configure do |config|
  config.metrics_provider = :prometheus
  config.metrics_port = 9394
  config.metrics_bind = "127.0.0.1"
end
```

Or enable the endpoint when starting a worker:

```bash
bundle exec temporal-worker --metrics-port 9394
curl http://localhost:9394/metrics
```

Use `--metrics-bind 0.0.0.0` only when Prometheus scrapes the worker from outside the process namespace, such as from another container or pod.

## Metrics

| Metric | Type | Labels | Description |
| --- | --- | --- | --- |
| `activejob_temporal_jobs_enqueued_total` | Counter | `class`, `queue` | Jobs successfully enqueued as Temporal workflows. `queue` is the ActiveJob queue name. Duplicate workflow starts are not counted. |
| `activejob_temporal_jobs_completed_total` | Counter | `class`, `queue` | Jobs that completed inside the activity runner. `queue` is the ActiveJob queue name. |
| `activejob_temporal_jobs_failed_total` | Counter | `class`, `queue`, `error` | Jobs that raised during activity execution. `queue` is the ActiveJob queue name. |
| `activejob_temporal_job_duration_seconds` | Histogram | `class` | Wall-clock duration of activity runner setup, middleware, and `job.perform`. |
| `activejob_temporal_payload_size_bytes` | Histogram | `class` | Serialized job payload size before enqueue. Oversized payloads are observed before `ActiveJob::SerializationError` is raised. |
| `activejob_temporal_retries_total` | Counter | `class`, `error` | Failed retry attempts where the Temporal activity attempt is greater than 1. |
| `activejob_temporal_active_workers` | Gauge | none | `1` while this worker process is running, `0` after shutdown starts. |
| `activejob_temporal_active_tasks` | Gauge | none | Active activity tasks executing in this worker process. |

The metrics endpoint returns Prometheus text format at `GET /metrics`.

Metrics are process-local. Worker scrapes expose worker lifecycle, active task, completed job, failed job, duration, and retry metrics. Enqueue and payload size metrics are recorded by the process that calls `perform_later`, usually a Rails web or job producer process. To scrape those series, expose the same provider from an internal Rails route or another process-local exporter:

```ruby
get "/activejob_temporal/metrics", to: proc {
  [
    200,
    { "Content-Type" => "text/plain; version=0.0.4" },
    [ActiveJob::Temporal::Metrics.render]
  ]
}
```

Protect any application-level metrics route the same way you protect other internal Prometheus scrape endpoints.

## Prometheus Scrape Config

```yaml
scrape_configs:
  - job_name: activejob-temporal-workers
    metrics_path: /metrics
    static_configs:
      - targets:
          - worker-1.example.com:9394
          - worker-2.example.com:9394

  - job_name: activejob-temporal-rails
    metrics_path: /activejob_temporal/metrics
    static_configs:
      - targets:
          - web-1.example.com:3000
```

For Kubernetes, expose a named metrics port on the worker container and point your `ServiceMonitor` or scrape config at `/metrics`.

## Useful Queries

```promql
sum(rate(activejob_temporal_jobs_enqueued_total[5m])) by (class, queue)
```

```promql
sum(rate(activejob_temporal_jobs_failed_total[5m])) by (class, queue, error)
```

```promql
histogram_quantile(0.95, sum(rate(activejob_temporal_job_duration_seconds_bucket[5m])) by (le, class))
```

```promql
histogram_quantile(0.95, sum(rate(activejob_temporal_payload_size_bytes_bucket[5m])) by (le, class))
```

```promql
sum(activejob_temporal_active_tasks)
```

## Grafana Dashboard

A starter dashboard is available at [`../examples/grafana/activejob_temporal_dashboard.json`](../examples/grafana/activejob_temporal_dashboard.json).

Import it in Grafana, choose your Prometheus data source, then adjust panels for your job classes and queues. Scrape Rails or other enqueueing processes if you want the enqueue and payload-size panels to have data.
