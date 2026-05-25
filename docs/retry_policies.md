# Retry Policy Guide

activejob-temporal keeps ActiveJob retry declarations as the source of truth for job behavior, while Temporal provides durable retry execution.

## Execution Model

ActiveJob does not expose `retry_on` and `discard_on` metadata through a public configuration API. activejob-temporal reads the handler metadata when a job is enqueued and stores a Temporal retry envelope in the workflow payload. If retry metadata cannot be read after a framework change, the gem logs a warning and falls back to configured retry defaults instead of failing enqueue.

The retry envelope gives Temporal enough activity attempts to cover the job's declared retry budget. When multiple `retry_on` declarations exist, the envelope uses the broadest attempt budget, including unlimited attempts when any matching declaration is unlimited.

The exact retry decision happens at activity runtime:

1. ActiveJob deserializes the job and runs `perform_now`.
2. ActiveJob selects `retry_on`, `discard_on`, and `rescue_from` handlers using normal handler precedence.
3. When `retry_on` calls `retry_job`, activejob-temporal converts that request into a retryable Temporal application error.
4. Temporal records the failed activity attempt and schedules the next attempt in workflow history.
5. When the matching `retry_on` declaration is exhausted, activejob-temporal raises a non-retryable Temporal application error so retries stop.

## Defaults

Unless configured otherwise, examples use:

```ruby
ActiveJob::Temporal.configure do |config|
  config.default_retry_initial_interval = 30.seconds
  config.default_retry_backoff = 2.0
  config.default_retry_max_attempts = 1
end
```

`attempts:` is the total number of activity attempts, including the first execution. For example, `attempts: 5` allows one initial activity attempt plus four retries.

`attempts: :unlimited` maps to Temporal unlimited activity attempts. The activity retries until it succeeds, is cancelled, reaches a timeout, or raises a non-retryable error.

## Quick Mapping

| ActiveJob pattern | Temporal behavior |
| --- | --- |
| No `retry_on` | Uses configured defaults. With the default `maximum_attempts: 1`, the job runs once. |
| `retry_on StandardError, wait: 60.seconds, attempts: 5` | Matching failures retry up to 5 total attempts. Temporal uses a 60 second retry delay request for `retry_job`. |
| Multiple `retry_on` declarations | ActiveJob chooses the matching handler at failure time using reverse declaration precedence. |
| `attempts: :unlimited` | Temporal receives an unlimited retry envelope. |
| `discard_on UnprocessableJobError` | ActiveJob handles the discard path. Matching unhandled errors are treated as non-retryable. |
| Symbol or Proc `wait:` | ActiveJob can still request the retry, but Temporal can only receive a numeric retry delay. Non-numeric waits fall back to the outer retry policy timing. |
| Non-numeric `attempts:` | Falls back to `default_retry_max_attempts` and logs `retry_attempts_fallback`. |
| `dead_letter_after_attempts = 3` | DLQ routing caps the outer retry envelope at 3 attempts before parking the failed job. |

## Common Patterns

### Default Policy

Jobs without `retry_on` or `discard_on` use configured defaults.

```ruby
class SyncCustomerJob < ApplicationJob
  def perform(customer_id)
    # ...
  end
end
```

With the default `maximum_attempts: 1`, Temporal tries the activity once and does not retry after a failure.

### Fixed Delay

```ruby
class SendInvoiceJob < ApplicationJob
  retry_on SomeTransientError, wait: 60.seconds, attempts: 5
end
```

When `SomeTransientError` is raised, ActiveJob selects that handler and calls `retry_job`. activejob-temporal converts the retry request into a retryable Temporal application error with a 60 second retry delay. Temporal retries the same activity until the job succeeds or reaches 5 total attempts.

### Multiple `retry_on` Declarations

```ruby
class MultiRetryJob < ApplicationJob
  retry_on StandardError, wait: 40.seconds, attempts: 2
  retry_on Timeout::Error, wait: 10.seconds, attempts: 6
end
```

ActiveJob evaluates retry handlers in reverse declaration order. `Timeout::Error` matches the second declaration and may run for 6 total attempts. Other `StandardError` failures match the broader declaration and stop after 2 total attempts.

The Temporal retry envelope is broad enough for the larger budget, but activejob-temporal checks the matching ActiveJob handler on every failure. When the selected handler is exhausted, it marks the error non-retryable so Temporal stops retrying.

### Discard Non-Retryable Errors

```ruby
class ImportRowJob < ApplicationJob
  discard_on UnprocessableRowError
end
```

`discard_on` runs through ActiveJob's normal rescue path. If ActiveJob handles the discard, including any discard block and `after_discard` callbacks, the activity completes from Temporal's perspective.

### Retry Some Errors, Discard Others

```ruby
class ChargeCardJob < ApplicationJob
  retry_on PaymentGatewayTimeout, wait: 15.seconds, attempts: 4
  discard_on InvalidCardError
end
```

`PaymentGatewayTimeout` follows the retry handler. `InvalidCardError` follows the discard handler. Unhandled errors use the outer retry envelope unless they match discard metadata or exhaust a matching `retry_on` declaration.

### Algorithmic Wait Strategies

```ruby
class ReportJob < ApplicationJob
  retry_on StandardError, wait: :exponentially_longer, attempts: 5
end
```

Temporal retry delay overrides must be numeric. Symbol and Proc waits still let ActiveJob decide that a retry should happen, but activejob-temporal falls back to the configured Temporal retry timing when it cannot convert the wait to seconds.

Use static `wait:` values and tune `default_retry_backoff` when you need a predictable retry curve in Temporal history.

### Invalid Attempt Values

```ruby
class InvalidAttemptsJob < ApplicationJob
  retry_on StandardError, wait: 10.seconds, attempts: "five"
end
```

Non-numeric attempt values fall back to `default_retry_max_attempts` and emit `retry_attempts_fallback`.

## Dead Letter Queue Interaction

When `dead_letter_queue` is enabled, jobs move to a Temporal-backed DLQ workflow after activity retries are exhausted. If `dead_letter_after_attempts` is configured, it overrides the generated outer `maximum_attempts` so the DLQ threshold controls when the job is parked. If `dead_letter_auto_discard_after` is configured, pending DLQ workflows auto-discard after that retention window.

## Troubleshooting

### My Job Did Not Retry

Check the matching handler's `attempts:` value. A value of `1` means one total activity attempt and no retries. Use `attempts: 2` or higher to allow retry attempts.

Also check whether `discard_on` or a custom `rescue_from` handler handled the exception inside ActiveJob. A handled exception completes the activity from Temporal's perspective.

### My `:exponentially_longer` Wait Became The Default Delay

Temporal can only receive numeric retry delays. Symbol and Proc waits fall back to `default_retry_initial_interval` and the outer retry policy timing. Use a static wait value, for example `wait: 15.seconds`, when the Temporal delay must be exact.

### My Discarded Error Retried Anyway

Make sure the raised error class matches a `discard_on` declaration. Matching respects Ruby inheritance. If the error is wrapped by application code before it reaches ActiveJob, declare the wrapper class or re-raise the original error.

### My Multiple Retry Rules Used The Wrong Budget

ActiveJob uses reverse declaration precedence. Put specific rules after broader rules:

```ruby
retry_on StandardError, wait: 40.seconds, attempts: 2
retry_on Timeout::Error, wait: 10.seconds, attempts: 6
```

In that order, `Timeout::Error` receives the specific 6-attempt budget and other `StandardError` failures receive the 2-attempt budget.
