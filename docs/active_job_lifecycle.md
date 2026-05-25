# ActiveJob Lifecycle Guide

activejob-temporal runs jobs through ActiveJob's execution contract while Temporal owns durability, retries, scheduling, and workflow coordination.

## Execution Model

`perform_later` serializes the full ActiveJob job data and stores it in the workflow payload alongside Temporal control metadata. The Temporal workflow owns durable concerns such as schedule delays, rate limits, dependency gates, child workflows, chains, and activity retry execution.

When the workflow reaches a Rails-backed job activity, `AjRunnerActivity` deserializes the stored job data through ActiveJob and runs `perform_now` inside the configured activejob-temporal middleware chain.

```text
perform_later
  -> ActiveJob serializes the job
  -> Temporal workflow starts with ActiveJob data and Temporal controls
  -> AjRunnerActivity deserializes the job
  -> activejob-temporal middleware wraps job.perform_now
  -> ActiveJob runs callbacks, perform, and rescue handlers
```

External Temporal activities and workflows in `chain:` or `child_workflows:` are not ActiveJob jobs. They use Temporal inputs, outputs, and retry options directly, so ActiveJob callbacks, middleware, argument serialization, and rescue handlers do not run for those external steps.

## Preserved ActiveJob State

The activity restores job state from ActiveJob serialization before calling `perform_now`. That includes:

- `job_id`
- `provider_job_id`
- `queue_name`
- `priority`
- serialized arguments
- `executions`
- `exception_executions`
- locale and timezone
- `enqueued_at` and `scheduled_at`

Job classes that override `serialize` and `deserialize` keep that custom state. The custom data travels with the durable workflow payload and is available when the worker executes the job activity.

## Callbacks, Middleware, And Rescue

`before_perform`, `around_perform`, and `after_perform` run in ActiveJob's normal order. activejob-temporal middleware wraps the ActiveJob execution, so middleware sees the hydrated job object and can add tracing, tenant context, logging, cleanup, or metrics around `perform_now`.

ActiveJob rescue handlers run through the normal `rescue_from` path. That includes explicit `rescue_from` handlers, `retry_on`, `discard_on`, and `after_discard`.

## Retry And Discard Semantics

Temporal owns durable retry execution, while ActiveJob owns handler selection.

When `retry_on` asks ActiveJob to `retry_job`, activejob-temporal intercepts that request and raises a retryable Temporal application error instead of enqueueing a second ActiveJob job. Temporal records the failed activity attempt and schedules the retry in workflow history.

At runtime, the raised exception selects the matching ActiveJob `retry_on` handler using ActiveJob precedence. The matching handler controls the retry delay and attempt limit. When the matching handler is exhausted, activejob-temporal raises a non-retryable Temporal application error so the activity stops retrying.

`discard_on` handlers run inside ActiveJob. If ActiveJob handles the discard, including any discard block and `after_discard`, the activity completes from Temporal's perspective. Unhandled exceptions propagate to Temporal unless activejob-temporal can classify them as non-retryable from discard metadata.

Payload deserialization failures that happen before the job can be hydrated are non-retryable, because retrying the same unreadable payload would not change the outcome.

## Legacy Payloads

Older activejob-temporal payloads stored a smaller set of job fields outside ActiveJob's serialized job data. The activity still reconstructs enough ActiveJob job data to execute those payloads. New payloads store full ActiveJob serialization so future executions preserve the complete lifecycle state.
