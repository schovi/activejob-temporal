# Middleware

`ActiveJob::Temporal` middleware wraps job execution inside `AjRunnerActivity`. Use it for cross-cutting runtime behavior such as tracing, metrics, custom logging, tenant context, or request-scoped cleanup.

Middleware runs after the job payload is deserialized and before `job.perform(*args)` is called. It does not run inside Temporal workflows, so middleware code can use normal Ruby side effects without affecting workflow determinism.

## Register Middleware

Register middleware once during application boot:

```ruby
# config/initializers/activejob_temporal.rb
class TracingMiddleware
  def call(job)
    span = Tracer.start_span(job.class.name)
    yield
  ensure
    span&.finish
  end
end

ActiveJob::Temporal.configure do |config|
  config.add_middleware TracingMiddleware
end
```

Middleware receives the ActiveJob instance and must yield to continue job execution.

```ruby
class TenantContextMiddleware
  def call(job)
    tenant_id = job.arguments.first.tenant_id
    Current.tenant_id = tenant_id
    yield
  ensure
    Current.tenant_id = nil
  end
end
```

## Constructor Arguments

Built-in Prometheus metrics do not require custom middleware. Enable `config.metrics_provider = :prometheus` and use the worker `GET /metrics` endpoint for worker-side metrics. Custom middleware is still useful when you need application-specific metrics beyond the built-in job counters, duration histograms, payload size histograms, retry counters, and worker gauges.

Pass constructor arguments when registering middleware classes:

```ruby
class MetricsMiddleware
  def initialize(registry)
    @registry = registry
  end

  def call(job)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    @registry.observe("activejob_temporal_job_duration_seconds", duration, class: job.class.name)
  end
end

ActiveJob::Temporal.configure do |config|
  config.add_middleware MetricsMiddleware, PrometheusRegistry.instance
end
```

Callable instances are also supported:

```ruby
middleware = ->(job, &block) do
  Rails.logger.info("Starting #{job.class.name}")
  block.call
end

ActiveJob::Temporal.configure do |config|
  config.add_middleware middleware
end
```

## Ordering

Middleware runs in registration order. The first registered middleware wraps the rest of the chain:

```ruby
ActiveJob::Temporal.configure do |config|
  config.add_middleware FirstMiddleware
  config.add_middleware SecondMiddleware
end
```

Execution order:

```text
FirstMiddleware before
SecondMiddleware before
job.perform
SecondMiddleware after
FirstMiddleware after
```

## Return Values And Errors

The chain returns the value from `job.perform` unless middleware changes it.

Exceptions raised by middleware or the job propagate to `AjRunnerActivity`. Existing `discard_on` handling still maps matching job exceptions to non-retryable Temporal application errors. Other exceptions are re-raised so Temporal retry policies can handle them.
