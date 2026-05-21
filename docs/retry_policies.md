# Retry Policy Guide

This guide shows how ActiveJob retry declarations map to Temporal activity retry policies.

## How To Read The Examples

activejob-temporal builds one Temporal `RetryPolicy` for each enqueued job. The policy is stored in the workflow payload and later used when the workflow executes `AjRunnerActivity`.

Unless noted otherwise, examples assume the default retry configuration:

```ruby
ActiveJob::Temporal.configure do |config|
  config.default_retry_initial_interval = 30.seconds
  config.default_retry_backoff = 2.0
  config.default_retry_max_attempts = 1
end
```

`attempts:` maps to Temporal `maximum_attempts`, which is the total number of activity attempts, including the first execution. For example, `attempts: 5` allows one initial activity attempt plus four retries.

activejob-temporal reads `retry_on` and `discard_on` declarations from ActiveJob handler metadata because ActiveJob does not currently expose a public retry configuration API. If retry metadata cannot be read after a framework change, the gem logs a warning and uses the configured retry defaults instead of failing during enqueue. If `discard_on` binding metadata changes, the gem falls back to ActiveJob handler source information when available.

When `dead_letter_queue` is enabled, jobs move to a Temporal-backed DLQ workflow after activity retries are exhausted. If `dead_letter_after_attempts` is configured, it overrides the generated `maximum_attempts` so the DLQ threshold controls when the job is parked.

## Quick Mapping

| ActiveJob pattern | Temporal policy fields | Retry delays after the initial failed attempt |
| --- | --- | --- |
| No `retry_on` | `initial_interval: 30`, `backoff_coefficient: 2.0`, `maximum_attempts: 1` | None |
| `retry_on StandardError, wait: 60.seconds, attempts: 5` | `initial_interval: 60`, `backoff_coefficient: 2.0`, `maximum_attempts: 5` | 60s, 120s, 240s, 480s |
| Global `default_retry_backoff = 1.5` with `wait: 20.seconds, attempts: 4` | `initial_interval: 20`, `backoff_coefficient: 1.5`, `maximum_attempts: 4` | 20s, 30s, 45s |
| `attempts: :unlimited` | `maximum_attempts: 0` | Continues until success, cancellation, timeout, or a non-retryable error |
| `discard_on UnprocessableJobError` | `non_retryable_error_types: ["UnprocessableJobError"]` | None for matching errors |
| `retry_on` plus `discard_on` | Retry fields plus `non_retryable_error_types` | Retryable errors follow the retry policy, discarded errors stop immediately |
| Multiple `retry_on` declarations | First handler in ActiveJob precedence order, usually the last declared rule | Depends on the selected handler |
| Symbol or Proc `wait:` | Falls back to `default_retry_initial_interval` | Uses the configured Temporal backoff curve |
| Non-numeric `attempts:` | Falls back to `default_retry_max_attempts` | Depends on the configured default |
| `dead_letter_after_attempts = 3` | Sets `maximum_attempts: 3` for DLQ-enabled jobs | 2 retry delays, then parks the failed job in the DLQ |

## Common Patterns

### 1. Default Policy

Jobs without `retry_on` or `discard_on` use the configured defaults.

```ruby
class SyncCustomerJob < ApplicationJob
  def perform(customer_id)
    # ...
  end
end
```

Temporal policy:

```ruby
{
  initial_interval: 30,
  backoff_coefficient: 2.0,
  maximum_attempts: 1,
  non_retryable_error_types: []
}
```

With the default `maximum_attempts: 1`, Temporal tries the activity once and does not retry after a failure.

### 2. Fixed Delay

```ruby
class SendInvoiceJob < ApplicationJob
  retry_on SomeTransientError, wait: 60.seconds, attempts: 5
end
```

Temporal policy:

```ruby
{
  initial_interval: 60,
  backoff_coefficient: 2.0,
  maximum_attempts: 5,
  non_retryable_error_types: []
}
```

Retry delays after the initial failed attempt: 60s, 120s, 240s, 480s.

### 3. Fixed Delay With Custom Backoff

```ruby
ActiveJob::Temporal.configure do |config|
  config.default_retry_backoff = 1.5
end

class SyncInventoryJob < ApplicationJob
  retry_on NetworkError, wait: 20.seconds, attempts: 4
end
```

Temporal policy:

```ruby
{
  initial_interval: 20,
  backoff_coefficient: 1.5,
  maximum_attempts: 4,
  non_retryable_error_types: []
}
```

Retry delays after the initial failed attempt: 20s, 30s, 45s.

### 4. Unlimited Retries

```ruby
class RefreshCacheJob < ApplicationJob
  retry_on TransientCacheError, wait: 30.seconds, attempts: :unlimited
end
```

Temporal policy:

```ruby
{
  initial_interval: 30,
  backoff_coefficient: 2.0,
  maximum_attempts: 0,
  non_retryable_error_types: []
}
```

Temporal treats `maximum_attempts: 0` as unlimited. The activity retries until it succeeds, is cancelled, reaches a timeout, or raises a non-retryable error.

### 5. Discard Non-Retryable Errors

```ruby
class ImportRowJob < ApplicationJob
  discard_on UnprocessableRowError
end
```

Temporal policy:

```ruby
{
  initial_interval: 30,
  backoff_coefficient: 2.0,
  maximum_attempts: 1,
  non_retryable_error_types: ["UnprocessableRowError"]
}
```

If the job raises `UnprocessableRowError`, the activity raises a non-retryable Temporal application error and Temporal does not retry it.

### 6. Retry Some Errors, Discard Others

```ruby
class ChargeCardJob < ApplicationJob
  retry_on PaymentGatewayTimeout, wait: 15.seconds, attempts: 4
  discard_on InvalidCardError
end
```

Temporal policy:

```ruby
{
  initial_interval: 15,
  backoff_coefficient: 2.0,
  maximum_attempts: 4,
  non_retryable_error_types: ["InvalidCardError"]
}
```

`PaymentGatewayTimeout` follows the retry policy with delays of 15s, 30s, and 60s. `InvalidCardError` is non-retryable and stops immediately.

### 7. Multiple `retry_on` Declarations

```ruby
class MultiRetryJob < ApplicationJob
  retry_on StandardError, wait: 40.seconds, attempts: 2
  retry_on SpecificError, wait: 10.seconds, attempts: 6
end
```

ActiveJob evaluates retry handlers in reverse declaration order. activejob-temporal attaches one Temporal retry policy when the job is enqueued, before any raised exception exists, so it uses the first handler in that precedence order.

In this example, the attached policy uses the `SpecificError` declaration:

```ruby
{
  initial_interval: 10,
  backoff_coefficient: 2.0,
  maximum_attempts: 6,
  non_retryable_error_types: []
}
```

Retry delays after the initial failed attempt: 10s, 20s, 40s, 80s, 160s.

If different exception families need different retry timing during the same job execution, prefer separate job classes. A single Temporal activity execution has one retry policy.

### 8. Algorithmic Wait Strategies

```ruby
class ReportJob < ApplicationJob
  retry_on StandardError, wait: :exponentially_longer, attempts: 5
end
```

Temporal policies cannot store arbitrary Ruby wait functions. Symbol and Proc waits fall back to `default_retry_initial_interval`.

Temporal policy with default configuration:

```ruby
{
  initial_interval: 30,
  backoff_coefficient: 2.0,
  maximum_attempts: 5,
  non_retryable_error_types: []
}
```

Retry delays after the initial failed attempt: 30s, 60s, 120s, 240s.

Use static `wait:` values and tune `default_retry_backoff` when you need a predictable curve. See [Migration Guide - Known Limitations](migration_guide.md#known-limitations) for migration notes.

### 9. Proc Wait Fallback

```ruby
class DynamicWaitJob < ApplicationJob
  retry_on StandardError, wait: ->(_executions) { 15.seconds }, attempts: 3
end
```

Proc waits are not executed. With default configuration, the policy uses:

```ruby
{
  initial_interval: 30,
  backoff_coefficient: 2.0,
  maximum_attempts: 3,
  non_retryable_error_types: []
}
```

Retry delays after the initial failed attempt: 30s, 60s.

### 10. Invalid Attempt Values

```ruby
class InvalidAttemptsJob < ApplicationJob
  retry_on StandardError, wait: 10.seconds, attempts: "five"
end
```

Non-numeric attempt values fall back to `default_retry_max_attempts`.

Temporal policy with default configuration:

```ruby
{
  initial_interval: 10,
  backoff_coefficient: 2.0,
  maximum_attempts: 1,
  non_retryable_error_types: []
}
```

## Troubleshooting

### My job did not retry

Check `maximum_attempts`. A value of `1` means one total activity attempt and no retries. Use `attempts: 2` or higher to allow retry attempts.

### My `:exponentially_longer` wait became 30 seconds

Symbol and Proc waits fall back to `default_retry_initial_interval`. Use a static wait value, for example `wait: 15.seconds`, and tune `default_retry_backoff` for the exponential curve.

### My discarded error retried anyway

Make sure the raised error class matches a `discard_on` declaration. `discard_on` entries become Temporal `non_retryable_error_types`, and matching respects Ruby inheritance.

### My multiple retry rules picked the wrong wait

Declare the retry rule you want Temporal to use after broader rules, and keep in mind that only one Temporal retry policy is attached to the activity at execution time.

### I need different retry curves for different errors

Prefer separate job classes when different exception families require substantially different retry timing. A single Temporal activity execution has one retry policy.
