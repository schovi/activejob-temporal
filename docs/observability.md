# Observability

`ActiveJob::Temporal` always emits Rails `ActiveSupport::Notifications` events. Vendor metrics and tracing backends are opt-in adapters.

## Rails Events

Subscribe to events with the `.activejob_temporal` namespace:

```ruby
ActiveSupport::Notifications.subscribe(/\.activejob_temporal\z/) do |name, _started, _finished, _id, payload|
  Rails.logger.info("activejob_temporal_event", event: name, **payload)
end
```

Built-in events include:

- `enqueue.activejob_temporal`
- `payload_serialize.activejob_temporal`
- `perform.activejob_temporal`
- `retry.activejob_temporal`
- `worker_start.activejob_temporal`
- `worker_stop.activejob_temporal`
- `active_tasks.activejob_temporal`

Payloads include stable correlation fields when available: `job_id`, `job_class`, `queue`, `workflow_id`, `run_id`, `attempt`, `worker_id`, `namespace`, and `task_queue`.

## Prometheus

```ruby
gem "prometheus-client"
require "activejob/temporal/observability/prometheus"

ActiveJob::Temporal.configure do |config|
  config.observability.use :prometheus do |prometheus|
    prometheus.metrics_server.port = 9394
  end
end
```

See [Metrics Guide](metrics.md) for metric names and scrape setup.

## OpenTelemetry

```ruby
gem "opentelemetry-sdk"
require "activejob/temporal/observability/opentelemetry"

ActiveJob::Temporal.configure do |config|
  config.observability.use :opentelemetry
end
```

The adapter creates spans and propagates trace context from enqueue into the Temporal payload so Rails request traces can connect to worker execution.

## Datadog

```ruby
gem "datadog"
require "activejob/temporal/observability/datadog"

ActiveJob::Temporal.configure do |config|
  config.observability.use :datadog do |datadog|
    datadog.service = "activejob-temporal"
  end
end
```

The adapter creates Datadog APM spans and sends DogStatsD custom metrics through the local Datadog Agent.
DogStatsD metrics are not tagged with `workflow_id`; per-workflow correlation stays on APM spans through the `activejob_temporal.workflow_id` tag.
