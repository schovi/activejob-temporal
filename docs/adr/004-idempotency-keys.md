# ADR 004: Thread-Local Idempotency Keys

## Status

Accepted

## Context

Background jobs frequently interact with external APIs that require idempotency guarantees: payment processors (Stripe, Braintree), third-party services (Twilio, SendGrid), and REST APIs. These systems use idempotency keys to ensure that duplicate requests (due to retries or network failures) do not cause duplicate side effects (charging a customer twice, sending duplicate notifications, etc.).

### The Retry Challenge

Temporal automatically retries activities on transient failures. Consider this scenario:

1. **Attempt 1**: Job calls payment API with network timeout after 5 seconds. Payment is processed but response is lost.
2. **Attempt 2**: Temporal retries the activity. Job calls payment API again with the same data.
3. **Result**: Customer is charged twice.

The solution is idempotency keys: unique tokens that APIs use to deduplicate requests. If a request with the same idempotency key is received twice, the API returns the original result without re-executing the operation.

### Requirements for ActiveJob Integration

1. **Uniqueness per Job Execution**: Each job execution needs a unique idempotency key. However, all retries of the *same* job execution must use the *same* key.

2. **Accessibility in Job Code**: Jobs must be able to read the idempotency key inside their `perform` method without changing ActiveJob's method signature.

3. **No API Changes**: The solution cannot require modifying ActiveJob's API. We cannot add parameters to `perform` or require jobs to inherit from a custom base class.

4. **Thread Safety**: Temporal workers execute multiple activities concurrently in the same Ruby process. Keys for different jobs must not interfere with each other.

5. **Deterministic and Recoverable**: If an activity execution fails and restarts on a different worker machine, the idempotency key must be the same. This ensures external API idempotency works across worker failures.

6. **Optional Usage**: Not all jobs need idempotency keys. The mechanism should be available but not mandatory.

### The Design Space

Several approaches could provide idempotency keys to jobs:

1. **Pass as Argument**: Add an idempotency key parameter to the job's `perform` method—**violates "no API changes" requirement**.

2. **Instance Variable**: Set `@idempotency_key` on the job instance—**not accessible in job code without coupling to the gem**.

3. **Global Variable**: Use a global variable like `$idempotency_key`—**not thread-safe; values would collide across concurrent activities**.

4. **Thread-Local Storage**: Use `Thread.current[:key]` to store keys per execution thread—**thread-safe, accessible, no API changes**.

5. **Context Object**: Pass a context object with job metadata—**requires changing ActiveJob's internal execution flow, complex**.

Thread-local storage emerged as the only approach satisfying all requirements.

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

The `set_idempotency_key` method retrieves the workflow ID from Temporal's activity context and constructs the key:

```ruby
# lib/activejob/temporal/activities/aj_runner_activity.rb (lines 84-85, 132-142)

# Thread-local key for storing the idempotency token.
IDEMPOTENCY_KEY = :aj_temporal_idempotency_key

def set_idempotency_key
  workflow_id = if defined?(Temporalio::Activity::Context) && Temporalio::Activity::Context.exist?
                  Temporalio::Activity::Context.current.info.workflow_id
                elsif Temporalio::Activity.respond_to?(:info)
                  # For unit tests with stub
                  Temporalio::Activity.info&.workflow_id || "unknown-workflow"
                else
                  "unknown-workflow"
                end
  Thread.current[IDEMPOTENCY_KEY] = "#{workflow_id}/runner"
end
```

**Key Components:**

1. **Deterministic Base**: The workflow ID (`ajwf:SendInvoiceJob:abc-123`) is deterministic per job and persists across retries.

2. **Namespace Suffix**: The `/runner` suffix namespaces the key within the workflow. If future features add other activities with separate keys, they could use `/validator` or `/notifier`.

3. **Thread Safety**: `Thread.current[]` isolates keys per execution thread. Concurrent activities in the same worker process have separate keys.

4. **Cleanup**: The `ensure` block clears the key after job execution, preventing leakage to thread pool reuse.

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

**Example Values:**

```ruby
# For a job enqueued as:
CreatePaymentJob.perform_later(123, 5000)

# The idempotency key would be:
"ajwf:CreatePaymentJob:5a3e8f1b-2c9d-4e7f-8b0a-1d2c3e4f5a6b/runner"
#  ^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^
#  Workflow ID base   Job ID (UUID)                       Namespace suffix
```

**Retry Behavior:**

If the job fails and Temporal retries the activity:

- **Same Workflow Execution**: The workflow ID remains identical across retries.
- **Same Idempotency Key**: The reconstructed key is identical to the first attempt.
- **API Deduplication**: External APIs receive the same idempotency key and return the original result.

### Workflow Lifecycle

```
1. Temporal starts workflow "ajwf:CreatePaymentJob:abc-123"
2. Workflow starts activity (AjRunnerActivity)
3. Activity sets Thread.current[:aj_temporal_idempotency_key] = "ajwf:CreatePaymentJob:abc-123/runner"
4. Activity calls job.perform(123, 5000)
   └─> Job code reads Thread.current[:aj_temporal_idempotency_key]
   └─> Job calls Stripe API with idempotency_key: "ajwf:CreatePaymentJob:abc-123/runner"
5. Activity clears Thread.current[:aj_temporal_idempotency_key] = nil
```

**On Retry (if step 4 fails):**

```
1. Temporal retries the activity in the SAME workflow
2. Activity sets Thread.current[:aj_temporal_idempotency_key] = "ajwf:CreatePaymentJob:abc-123/runner" (SAME KEY)
3. Activity calls job.perform(123, 5000)
   └─> Job calls Stripe API with idempotency_key: "ajwf:CreatePaymentJob:abc-123/runner" (SAME KEY)
   └─> Stripe recognizes duplicate request and returns original result
```

## Consequences

### Positive

- **Zero API Changes**: Jobs access idempotency keys without modifying `perform` signatures. Existing ActiveJob code works unchanged.

- **Thread Safety**: Concurrent activities in a multi-threaded worker process have isolated keys. No risk of key collision or race conditions.

- **Deterministic Keys Across Retries**: The workflow ID-based approach ensures retries use the same key, enabling true idempotency with external APIs.

- **Cross-Worker Recovery**: If an activity fails and restarts on a different worker machine, the workflow ID is retrieved from Temporal's activity context, producing the same key.

- **Simple Access Pattern**: Reading `Thread.current[:aj_temporal_idempotency_key]` is straightforward and requires no gem-specific APIs.

- **Optional Usage**: Jobs that don't need idempotency simply ignore the key. There's no performance penalty or complexity for jobs that don't use it.

- **Standardized Key Format**: The `<workflow_id>/runner` format is consistent and debuggable. Developers can identify which workflow a key belongs to by inspection.

### Negative

- **Thread-Local Coupling**: Jobs must understand that idempotency keys are stored in thread-local storage. This is less explicit than a parameter or instance variable.

- **Documentation Dependency**: Developers need to know that `Thread.current[:aj_temporal_idempotency_key]` exists and how to use it. This information is not self-documenting in the job's method signature.

- **Testing Complexity**: Tests that verify idempotency key usage must mock or stub the activity execution context:
  ```ruby
  # In job specs:
  before do
    Thread.current[:aj_temporal_idempotency_key] = "test-key"
  end

  after do
    Thread.current[:aj_temporal_idempotency_key] = nil
  end
  ```

- **Limited to Thread-Per-Execution Model**: The approach assumes one activity execution per thread. If Temporal's Ruby SDK ever switches to a fiber-based or async execution model, thread-local storage would break.

  However, as of 2025, the Temporalio Ruby SDK uses thread-based activity execution, making this assumption safe.

- **Namespace Suffix Overhead**: The `/runner` suffix adds 7 characters to every key. While this is negligible for most APIs (Stripe accepts up to 255 characters), extremely length-constrained APIs might find this wasteful.

- **No Built-In Key Validation**: The gem doesn't validate whether external APIs successfully use the idempotency key. If a job passes a nil key or an API ignores it, the gem cannot detect this failure mode.

### Neutral

- **External API Dependency**: Idempotency only works if the external API supports idempotency keys. APIs without this feature cannot benefit from this mechanism (though they wouldn't break—they'd simply ignore the key).

## Alternatives Considered

### Alternative 1: Pass Idempotency Key as Job Argument

Modify the `perform` signature to include an idempotency key parameter:

```ruby
class CreatePaymentJob < ApplicationJob
  def perform(user_id, amount_cents, idempotency_key:)
    StripeClient.create_charge(
      amount: amount_cents,
      idempotency_key: idempotency_key
    )
  end
end

# Adapter injects key when calling perform:
job.perform(*args, idempotency_key: "ajwf:CreatePaymentJob:abc-123/runner")
```

**Why Not Chosen:**

- **Breaks ActiveJob API Contract**: ActiveJob specifies that `perform` receives the same arguments passed to `perform_later`. Injecting additional arguments breaks this contract.

- **Compatibility Issues**: Existing jobs would need to update their `perform` signatures, making migration difficult.

- **Test Friction**: Job specs would need to provide the idempotency key argument, even if the job doesn't use it.

### Alternative 2: Store in Job Instance Variable

Set an instance variable on the job object before calling `perform`:

```ruby
job = job_class.new
job.instance_variable_set(:@idempotency_key, "ajwf:CreatePaymentJob:abc-123/runner")
job.perform(*args)

# In job code:
class CreatePaymentJob < ApplicationJob
  def perform(user_id, amount_cents)
    idempotency_key = @idempotency_key
    # ...
  end
end
```

**Why Not Chosen:**

- **Undocumented Magic**: Instance variables set externally are invisible to developers reading the job code. There's no indication where `@idempotency_key` comes from.

- **Coupling to Gem**: Jobs would need to "know" that the activejob-temporal gem sets this variable, creating tight coupling.

- **Testing Difficulty**: Specs would need to set the instance variable manually, making tests verbose.

### Alternative 3: Global Variable

Use a global variable to store the current idempotency key:

```ruby
$current_idempotency_key = "ajwf:CreatePaymentJob:abc-123/runner"
job.perform(*args)

# In job code:
class CreatePaymentJob < ApplicationJob
  def perform(user_id, amount_cents)
    idempotency_key = $current_idempotency_key
    # ...
  end
end
```

**Why Not Chosen:**

- **Not Thread-Safe**: Global variables are shared across all threads. Concurrent activity executions would overwrite each other's keys:
  ```ruby
  # Thread 1 (Job A):
  $current_idempotency_key = "key-A"
  # Thread 2 (Job B) interrupts:
  $current_idempotency_key = "key-B" # Overwrites key-A!
  # Thread 1 continues:
  api.call(idempotency_key: $current_idempotency_key) # Uses wrong key-B!
  ```

- **Namespace Pollution**: Global variables are considered bad practice in Ruby and pollute the global namespace.

### Alternative 4: Context Object with Dynamic Binding

Introduce a context object passed through Ruby's fiber-local storage or block parameters:

```ruby
class CreatePaymentJob < ApplicationJob
  def perform(user_id, amount_cents)
    context = ActiveJob::Temporal.current_context
    idempotency_key = context.idempotency_key
    # ...
  end
end
```

**Why Not Chosen:**

- **Implementation Complexity**: Requires maintaining a context stack and handling edge cases (nested jobs, exceptions, thread boundaries).

- **Fiber-Local Storage Limitations**: Ruby's fiber-local storage (`Fiber[]`) doesn't work with thread-based execution models.

- **Overhead**: Adds a layer of abstraction that provides no clear benefit over `Thread.current[]`.

- **Documentation Burden**: Developers need to learn the context API instead of the standard `Thread.current` pattern.

### Alternative 5: Auto-Inject via Job Instrumentation

Use ActiveSupport::Notifications to instrument job execution and inject the key via callbacks:

```ruby
ActiveSupport::Notifications.subscribe("perform.active_job") do |event|
  Thread.current[:aj_temporal_idempotency_key] = derive_key_from(event)
end
```

**Why Not Chosen:**

- **Timing Issues**: Instrumentation hooks fire *around* job execution, not *before* it. There's no guarantee the key is set before `perform` runs.

- **Compatibility Risk**: ActiveSupport::Notifications is designed for observability, not execution flow control. Relying on it for critical functionality is fragile.

- **Still Requires Thread-Local Storage**: The key would still need to be stored in `Thread.current[]`, so this approach adds complexity without eliminating the thread-local dependency.

## References

- [Stripe Idempotent Requests](https://stripe.com/docs/api/idempotent_requests)
- [Ruby Thread-Local Storage](https://ruby-doc.org/core-3.0.0/Thread.html#class-Thread-label-Fiber-local+vs.+Thread-local)
- [Temporal Activity Context](https://docs.temporal.io/activities#activity-context)
- [ActiveJob Perform Documentation](https://guides.rubyonrails.org/active_job_basics.html#create-the-job)
