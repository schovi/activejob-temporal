# ADR 004: Thread-Local Idempotency Keys

## Status

Accepted

## Context

Background jobs frequently interact with external APIs that require idempotency guarantees: payment processors (Stripe, Braintree), third-party services (Twilio, SendGrid), and REST APIs. These systems use idempotency keys to ensure that duplicate requests (due to retries or network failures) do not cause duplicate side effects (charging a customer twice, sending duplicate notifications, etc.).

Temporal automatically retries activities on transient failures. Without idempotency keys, a payment API timeout that occurs after processing but before response delivery causes duplicate charges on retry. Idempotency keys enable APIs to deduplicate requests and return original results.

Requirements: unique key per job execution but same key across retries, accessible in job code without changing ActiveJob's API, no `perform` signature changes, thread safety (concurrent activities must not interfere), deterministic keys across worker failures, optional usage. Thread-local storage (`Thread.current[:key]`) is the only approach satisfying all requirements (vs. arguments violating API contract, instance variables requiring coupling, global variables lacking thread safety, context objects adding complexity).

## Decision

We provide **thread-local idempotency keys** that are set before job execution and accessible via `Thread.current[:aj_temporal_idempotency_key]`.

The idempotency key is derived from Temporal's workflow ID, which is deterministic per job (format: `ajwf:JobClass:job_id`). The key includes a `/runner` suffix to namespace it within the workflow's execution context.

### Implementation

#### Setting the Idempotency Key

The `AjRunnerActivity` sets the thread-local key before calling the job's `perform` method:

```ruby
# lib/activejob/temporal/activities/aj_runner_activity.rb (lines 108-121)

def execute(payload)
  job_class = nil

  args = Payload.deserialize_args(payload)
  job_class = constantize_job_class(payload)
  job = job_class.new

  set_idempotency_key
  job.perform(*args)
rescue StandardError => e
  handle_exception(job_class, e)
ensure
  Thread.current[IDEMPOTENCY_KEY] = nil
end
```

The key is constructed from Temporal's workflow ID with `/runner` suffix: `Thread.current[:aj_temporal_idempotency_key] = "#{workflow_id}/runner"`. Workflow ID (`ajwf:SendInvoiceJob:abc-123`) is deterministic per job and persists across retries. Thread-local storage isolates keys per execution thread. The `ensure` block clears keys after execution to prevent thread pool leakage.

#### Accessing the Idempotency Key in Jobs

Jobs can read the key from thread-local storage:

```ruby
class CreatePaymentJob < ApplicationJob
  def perform(user_id, amount_cents)
    user = User.find(user_id)
    idempotency_key = Thread.current[:aj_temporal_idempotency_key]

    StripeClient.create_charge(
      amount: amount_cents,
      customer: user.stripe_customer_id,
      idempotency_key: idempotency_key # Stripe deduplicates on this key
    )
  end
end
```

For `CreatePaymentJob.perform_later(123, 5000)`, the key is `"ajwf:CreatePaymentJob:5a3e8f1b-2c9d-4e7f-8b0a-1d2c3e4f5a6b/runner"`. On retry, the workflow ID remains identical, producing the same key. External APIs receive the same idempotency key and return the original result, preventing duplicate charges.

## Consequences

### Positive

- **Zero API Changes**: Jobs access keys without modifying `perform` signatures.
- **Thread Safety**: Concurrent activities have isolated keys, no collisions.
- **Deterministic Keys Across Retries**: Workflow ID-based approach ensures retries use same key.
- **Cross-Worker Recovery**: Activity restarts on different machines produce same key.
- **Simple Access Pattern**: `Thread.current[:aj_temporal_idempotency_key]` requires no gem-specific APIs.
- **Optional Usage**: No performance penalty for jobs not using idempotency.
- **Standardized Format**: `<workflow_id>/runner` format is consistent and debuggable.

### Negative

- **Thread-Local Coupling**: Jobs must understand that idempotency keys are stored in thread-local storage. This is less explicit than a parameter or instance variable.

- **Documentation Dependency**: Developers must know `Thread.current[:aj_temporal_idempotency_key]` exists (not self-documenting).
- **Testing Complexity**: Tests must manually set/clear thread-local keys.
- **Thread-Per-Execution Assumption**: Breaks if Ruby SDK switches to fiber-based execution (safe as of 2025).
- **No Built-In Validation**: Gem cannot detect if APIs ignore nil keys.

## Alternatives Considered

### Alternative 1: Pass Idempotency Key as Job Argument

Add `idempotency_key:` parameter to `perform`. **Why Not Chosen:** Breaks ActiveJob API contract (`perform` should receive same args as `perform_later`), requires updating existing job signatures, adds test friction.

### Alternative 2: Store in Job Instance Variable

Set `@idempotency_key` on job instance before calling `perform`. **Why Not Chosen:** Undocumented magic (invisible source of instance variable), tight coupling to gem, verbose test setup.

### Alternative 3: Context Object with Dynamic Binding

Introduce context object via fiber-local storage. **Why Not Chosen:** Implementation complexity (context stack, edge cases), fiber-local storage incompatible with thread-based execution, adds abstraction without clear benefit, documentation burden.

### Alternative 4: Auto-Inject via Job Instrumentation

Use `ActiveSupport::Notifications` to inject keys via callbacks. **Why Not Chosen:** Timing issues (hooks fire around execution, not before), compatibility risk (observability tool used for flow control), still requires thread-local storage (adds complexity without eliminating dependency).

## References

- [Stripe Idempotent Requests](https://stripe.com/docs/api/idempotent_requests)
- [Ruby Thread Documentation](https://docs.ruby-lang.org/en/master/Thread.html)
- [Temporal Activity Context](https://docs.temporal.io/activities#activity-context)
- [ActiveJob Perform Documentation](https://guides.rubyonrails.org/active_job_basics.html#create-the-job)
