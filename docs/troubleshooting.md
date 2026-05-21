# Troubleshooting Guide

Use this guide when activejob-temporal jobs do not enqueue, execute, retry, cancel, or appear in Temporal UI as expected.

Start with the smallest check that proves where the failure is:

```bash
bundle exec rails runner 'puts ActiveJob::Base.queue_adapter.class'
bundle exec rails runner 'puts ActiveJob::Temporal.config.target'
bundle exec rails runner 'puts ActiveJob::Temporal.config.namespace'
bundle exec rails runner 'puts ActiveJob::Temporal.config.task_queue'
```

Then check Temporal itself:

```bash
temporal operator namespace describe default
temporal workflow list --namespace default
temporal operator search-attribute list --namespace default
```

Replace `default` with your configured namespace.

## Jobs Not Appearing In Temporal

**Symptoms**

- `perform_later` returns, but no workflow appears in Temporal UI.
- Application logs do not include `workflow_enqueued`.
- `ActiveJob::Base.queue_adapter.class` does not include `Temporal`.

**Diagnostics**

```bash
bundle exec rails runner 'puts ActiveJob::Base.queue_adapter.class'
bundle exec rails runner 'puts Rails.application.config.active_job.queue_adapter'
```

**Fix**

Configure Rails to use the Temporal adapter:

```ruby
# config/application.rb or config/environments/production.rb
config.active_job.queue_adapter = :temporal
```

Restart the Rails process after changing the adapter. Initializers and environment-specific config are loaded at boot.

## Workflow Starts But Job Does Not Execute

**Symptoms**

- Workflow exists in Temporal UI and stays `Running`.
- Activity task queue grows in Temporal UI.
- No job-side log output appears.

**Diagnostics**

```bash
ACTIVEJOB_TEMPORAL_TARGET=localhost:7233 \
ACTIVEJOB_TEMPORAL_NAMESPACE=default \
ACTIVEJOB_TEMPORAL_TASK_QUEUE=default \
bundle exec temporal-worker
```

In Temporal UI, open the workflow and compare the activity task queue with `ACTIVEJOB_TEMPORAL_TASK_QUEUE`.

**Fix**

Run at least one worker polling the queue used by the job. If the job uses `queue_as :billing`, start a worker with:

```bash
ACTIVEJOB_TEMPORAL_TASK_QUEUE=billing bundle exec temporal-worker
```

If you configured `task_queue_prefix`, include the prefix when starting workers. For example, a prefix of `rails-` and queue `billing` requires a worker on `rails-billing`.

## Task Queue Mismatch

**Symptoms**

- Temporal UI shows pending activities on one queue.
- Workers are healthy but polling a different queue.

**Diagnostics**

```bash
bundle exec rails runner 'job = Class.new(ActiveJob::Base).new; job.queue_name = "billing"; puts ActiveJob::Temporal::Adapter.resolve_task_queue(job)'
bundle exec rails runner 'job = Class.new(ActiveJob::Base).new; job.queue_name = "billing"; job.priority = 10; puts ActiveJob::Temporal::Adapter.resolve_task_queue(job)'
bundle exec rails runner 'puts ActiveJob::Temporal.config.task_queue_prefix.inspect'
bundle exec rails runner 'puts ActiveJob::Temporal.config.priority_task_queues.inspect'
```

**Fix**

Align all three places:

- The job queue, for example `queue_as :billing`
- Any configured `priority_task_queues` mapping when the job uses `set(priority:)`
- The adapter task queue after any `task_queue_prefix`
- The worker `ACTIVEJOB_TEMPORAL_TASK_QUEUE`

## Temporal Connection Errors

**Error message**

```text
Unable to connect to Temporal at localhost:7233 (namespace: default): ...
```

**Diagnostics**

```bash
temporal operator namespace describe default --address localhost:7233
nc -vz localhost 7233
```

**Fix**

Check:

- `ACTIVEJOB_TEMPORAL_TARGET` points to the Temporal frontend host and port.
- `ACTIVEJOB_TEMPORAL_NAMESPACE` exists.
- Docker or Kubernetes networking allows the app and worker to reach Temporal.
- TLS settings match the cluster if using Temporal Cloud or mTLS.

## Namespace Does Not Exist

**Symptoms**

- Client connection or workflow start fails.
- Temporal CLI cannot describe the namespace.

**Diagnostics**

```bash
temporal operator namespace list --address localhost:7233
temporal operator namespace describe production --address localhost:7233
```

**Fix**

Create the namespace or point the app to an existing one:

```bash
temporal operator namespace create production --address localhost:7233
```

Then set:

```bash
ACTIVEJOB_TEMPORAL_NAMESPACE=production
```

## Search Attributes Not Registered

**Symptoms**

- Job enqueue fails when search attributes are attached.
- Status inspection or cancellation cannot find workflows by job class and job ID.
- Temporal reports invalid search attributes.

**Diagnostics**

```bash
temporal operator search-attribute list --namespace default
```

Required attributes:

```text
ajClass
ajQueue
ajJobId
ajEnqueuedAt
ajTenantId
ajTags
```

**Fix**

Register the attributes once per Temporal cluster:

```bash
temporal operator search-attribute create --namespace default \
  --name ajClass --type Keyword \
  --name ajQueue --type Keyword \
  --name ajJobId --type Keyword \
  --name ajEnqueuedAt --type Datetime \
  --name ajTenantId --type Int \
  --name ajTags --type KeywordList
```

Some Temporal deployments need a short delay before new search attributes are queryable.

## Payload Too Large Errors

**Error message**

```text
ActiveJob::SerializationError: Job payload size (350.5 KB) exceeds maximum allowed size (250 KB). Consider reducing argument size or using references (e.g., database IDs).
```

**Diagnostics**

Look for structured logs:

```text
payload_size_large
payload_size_near_limit
payload_size_exceeded
```

**Fix**

Pass references instead of full objects:

```ruby
# Prefer this
ProcessInvoiceJob.perform_later(invoice.id)

# Avoid large hashes, arrays, or file contents
ProcessInvoiceJob.perform_later(invoice.attributes)
```

For ActiveRecord models, prefer GlobalID-compatible records or IDs. Only raise `max_payload_size_kb` when you have measured the payload cost and confirmed Temporal cluster limits are acceptable:

```ruby
ActiveJob::Temporal.configure do |config|
  config.max_payload_size_kb = 512
end
```

## Payload Decryption Errors

**Error message**

```text
ActiveJob::SerializationError: Unable to decrypt ActiveJob::Temporal payload
```

**Diagnostics**

Check that every worker has the same primary key and old-key rotation set:

```bash
bundle exec rails runner 'puts "encrypt_payload=#{ActiveJob::Temporal.config.encrypt_payload}"'
bundle exec rails runner 'puts "encryption_key_present=#{!ActiveJob::Temporal.config.encryption_key.to_s.empty?}"'
bundle exec rails runner 'puts "old_key_count=#{ActiveJob::Temporal.config.encryption_old_keys.size}"'
```

**Fix**

Use Base64-encoded 32-byte keys, for example `SecureRandom.base64(32)`. During rotation, deploy the new key as `encryption_key` and keep the previous key in `encryption_old_keys` until workflows encrypted with the previous key have completed or aged out of Temporal history.

## Serialization Or Deserialization Errors

**Symptoms**

- Enqueue raises `ActiveJob::SerializationError`.
- Activity fails before calling `perform`.
- Error mentions unsupported argument types or missing records.

**Diagnostics**

```bash
bundle exec rails runner 'p ActiveJob::Arguments.serialize([YourModel.first])'
```

**Fix**

Use values ActiveJob can serialize:

- Primitive values such as strings, integers, booleans, arrays, and hashes
- GlobalID-compatible ActiveRecord records
- Database IDs that the job can reload

Avoid passing open files, IO objects, lambdas, service clients, and unsaved ActiveRecord records.

## Retries Not Working

**Symptoms**

- Job fails once and does not retry.
- Temporal UI shows `maximum_attempts: 1`.

**Diagnostics**

Open the workflow in Temporal UI and inspect the activity retry policy. Check the job declaration:

```ruby
class SyncCustomerJob < ApplicationJob
  retry_on Net::OpenTimeout, wait: 30.seconds, attempts: 5
end
```

**Fix**

Remember that `attempts:` is total attempts, including the first execution. Use `attempts: 2` or higher to allow at least one retry.

If the job has no `retry_on`, the gem uses `default_retry_max_attempts`, which defaults to `1`.

## Algorithmic Retry Waits Are Ignored

**Symptoms**

- `wait: :exponentially_longer` or a Proc wait does not produce the exact ActiveJob delay curve.
- Retry delay starts at `default_retry_initial_interval`.

**Cause**

Temporal retry policies store numeric intervals and a fixed backoff coefficient. They cannot persist arbitrary Ruby wait functions.

**Fix**

Use static waits and tune the global backoff:

```ruby
ActiveJob::Temporal.configure do |config|
  config.default_retry_backoff = 2.0
end

class SyncCustomerJob < ApplicationJob
  retry_on Net::OpenTimeout, wait: 15.seconds, attempts: 5
end
```

See [Retry Policy Guide](retry_policies.md) for the full mapping.

## Discarded Errors Retry Anyway

**Symptoms**

- A non-retryable business error keeps retrying.
- Temporal UI does not show the error in `non_retryable_error_types`.

**Diagnostics**

Check that the raised exception class matches the `discard_on` declaration:

```ruby
class ImportRowJob < ApplicationJob
  discard_on InvalidRowError

  def perform(row_id)
    raise InvalidRowError, "invalid row"
  end
end
```

**Fix**

Declare `discard_on` for the exact exception class or a superclass. If both `retry_on` and `discard_on` are present, confirm the error class is covered by `discard_on`.

## Scheduled Jobs Do Not Run When Expected

**Symptoms**

- `MyJob.set(wait: 5.minutes).perform_later` appears in Temporal UI as `Running`.
- The job does not call `perform` until later.
- Temporal history shows timer events before the activity starts.

**Diagnostics**

```bash
temporal workflow show --namespace default --workflow-id ajwf:MyJob:550e8400-e29b-41d4-a716-446655440000
```

Look for timer events in the workflow history. A scheduled ActiveJob is implemented as a Temporal workflow that sleeps until the requested time, then schedules the activity.

**Fix**

Check:

- The `wait:` or `wait_until:` value is what you expect after time zone conversion.
- The worker is running before the timer fires.
- The worker polls the job's task queue.
- The activity has not failed and moved into retry delay.

## Cancellation Does Not Stop The Job

**Symptoms**

- `ActiveJob::Temporal.cancel(MyJob, job_id)` returns without error.
- Workflow is canceled, but the Ruby code continues running to completion.

**Cause**

Long-running activities only observe cancellation promptly when they heartbeat or explicitly check cancellation.

**Fix**

Add heartbeats inside long loops:

```ruby
class ExportLargeReportJob < ApplicationJob
  temporal_options heartbeat_timeout: 30.seconds

  def perform(report_id)
    rows_for(report_id).each_slice(100) do |rows|
      Temporalio::Activity::Context.current.heartbeat
      export_rows(rows)
    end
  end
end
```

Without heartbeats, Temporal can mark the workflow canceled while the local activity thread finishes its current Ruby work.

## Status Or Cancellation Cannot Find A Workflow

**Status behavior**

`ActiveJob::Temporal.status(MyJob, job_id)` returns `nil` when no matching workflow exists.

**Cancellation error message**

```text
ActiveJob::Temporal::WorkflowNotFoundError: No workflow found for job_id 550e8400-e29b-41d4-a716-446655440000. The job may have never existed.
```

**Diagnostics**

```bash
temporal workflow list --namespace default --query 'ajClass = "MyJob"'
temporal workflow list --namespace default --query 'ajJobId = "550e8400-e29b-41d4-a716-446655440000"'
```

From Rails:

```ruby
ActiveJob::Temporal.status(MyJob, "550e8400-e29b-41d4-a716-446655440000")
```

**Fix**

Check:

- The `job_id` is the ActiveJob UUID, not the Temporal run ID.
- Search attributes were registered before the workflow was started.
- Custom `workflow_id_generator` values are valid and still attach the standard search attributes.
- The workflow has not aged out of Temporal retention.

## Invalid Job ID Format

**Error message**

```text
Invalid job_id format: expected UUID (e.g., '550e8400-e29b-41d4-a716-446655440000'), got: ...
```

**Fix**

Pass the ActiveJob `job_id`. Do not pass a database ID, Temporal workflow ID, or Temporal run ID:

```ruby
job = MyJob.perform_later(record.id)
ActiveJob::Temporal.status(MyJob, job.job_id)
ActiveJob::Temporal.cancel(MyJob, job.job_id)
```

## Invalid Custom Workflow ID

**Error messages**

```text
workflow_id_generator must return a String
workflow_id_generator returned an invalid workflow ID: only letters, numbers, underscore, hyphen, period, and colon are allowed
workflow_id_generator returned an invalid workflow ID: maximum length is 255 characters
```

**Fix**

Return a short string with only supported characters:

```ruby
ActiveJob::Temporal.configure do |config|
  config.workflow_id_generator = ->(job) { "tenant-42:ajwf:#{job.class.name}:#{job.job_id}" }
end
```

Avoid slashes, spaces, query fragments, and unbounded argument values.

## Activity Timeouts

**Symptoms**

- Workflow fails with activity timeout errors.
- Long jobs retry even though the worker is still alive.

**Diagnostics**

Open the workflow in Temporal UI and inspect the activity event history. Look for timeout type and attempt count.

**Fix**

Set timeouts that match the job behavior:

```ruby
class ExportLargeReportJob < ApplicationJob
  temporal_options(
    start_to_close_timeout: 30.minutes,
    heartbeat_timeout: 30.seconds
  )
end
```

Use `start_to_close_timeout` for total activity execution time. Use `heartbeat_timeout` only when the job sends regular heartbeats.

## Duplicate Enqueue Is Ignored

**Symptoms**

- A second enqueue with the same ActiveJob `job_id` does not start a new workflow.
- Logs show the workflow was already started.

**Cause**

Workflow IDs are deterministic by default: `ajwf:<JobClass>:<job_id>`. Temporal rejects duplicate workflow IDs while the previous execution is still retained.

**Fix**

Use the normal `perform_later` flow so ActiveJob generates a new `job_id`. Only customize `workflow_id_generator` when you intentionally want idempotency across enqueue attempts.

## Performance Or Queue Backlog

**Symptoms**

- Temporal UI shows growing workflow or activity task queues.
- Jobs execute, but with increasing latency.
- Worker CPU or database connections are saturated.

**Diagnostics**

Check queue depth in Temporal UI and worker logs:

```bash
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=100 \
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=5 \
bundle exec temporal-worker
```

**Fix**

Tune one bottleneck at a time:

- Increase `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES` when activity queue depth grows and the worker has spare CPU, memory, and database connections.
- Increase `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS` when workflow task latency grows.
- Reduce large payloads before increasing concurrency.
- Scale workers horizontally by running more worker processes on the same task queue.

See [Performance Tuning Guide](performance_tuning.md) for workload-specific tuning and [Worker Setup Guide](worker_setup.md) for worker startup examples.

## Configuration Checklist

Before escalating an issue, collect:

```bash
bundle exec rails runner 'puts "adapter=#{ActiveJob::Base.queue_adapter.class}"'
bundle exec rails runner 'puts "target=#{ActiveJob::Temporal.config.target}"'
bundle exec rails runner 'puts "namespace=#{ActiveJob::Temporal.config.namespace}"'
bundle exec rails runner 'puts "task_queue=#{ActiveJob::Temporal.config.task_queue}"'
bundle exec rails runner 'puts "task_queue_prefix=#{ActiveJob::Temporal.config.task_queue_prefix.inspect}"'
bundle exec rails runner 'puts "priority_task_queues=#{ActiveJob::Temporal.config.priority_task_queues.inspect}"'
bundle exec rails runner 'puts "metrics_provider=#{ActiveJob::Temporal.config.metrics_provider}"'
bundle exec rails runner 'puts "metrics_port=#{ActiveJob::Temporal.config.metrics_port.inspect}"'
bundle exec rails runner 'puts "max_payload_size_kb=#{ActiveJob::Temporal.config.max_payload_size_kb}"'
```

Temporal state:

```bash
temporal operator namespace describe default
temporal operator search-attribute list --namespace default
temporal workflow list --namespace default
```

Workflow-specific state:

```bash
temporal workflow describe --namespace default --workflow-id ajwf:MyJob:550e8400-e29b-41d4-a716-446655440000
temporal workflow show --namespace default --workflow-id ajwf:MyJob:550e8400-e29b-41d4-a716-446655440000
```

## Getting Help

When opening an issue, include:

- activejob-temporal version
- Ruby and Rails versions
- Temporal server or Temporal Cloud version
- Worker command and environment variables with secrets removed
- Job class with `queue_as`, `set(priority:)` if used, `retry_on`, `discard_on`, and `temporal_options`
- Exact error message
- Workflow ID and run ID if available
- Relevant structured log events such as `workflow_enqueued`, `payload_size_exceeded`, `cancellation_requested`, or audit events like `job.failed`

Do not include credentials, TLS private keys, customer data, or full job arguments containing sensitive data.
