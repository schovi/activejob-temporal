# Migration Guide: From Traditional Job Queues to activejob-temporal

Practical migration instructions from Sidekiq/Resque/Delayed Job to activejob-temporal backed by Temporal.

---

## 1. Why Migrate

- **Durable execution:** Jobs survive failures and restarts without external queue storage
- **Superior observability:** Real-time monitoring and debugging via Temporal UI
- **Built-in fault tolerance:** Battle-tested retry policies
- **Simplified operations:** No separate Redis/PostgreSQL queue infrastructure

**Best for:** High-reliability applications, complex orchestration, teams using Temporal.

---

## 2. Prerequisites

- Temporal cluster access (self-hosted or Temporal Cloud)
- Ruby >= 4.0, Rails >= 7.2
- Add `gem "activejob-temporal"` to Gemfile
- Register search attributes (see [README](../README.md#step-3-register-search-attributes-one-time-setup))

**Docs:** [README](../README.md) | [Configuration Reference](configuration_reference.md) | [Worker Setup Guide](worker_setup.md)

### Ruby 4 Upgrade Note

Ruby 4 support requires Temporal Ruby SDK 1.4.x. Workflow code must use deterministic payload values instead of reading process configuration directly. New workflows serialize global activity timeout defaults into the workflow payload at enqueue time. Before upgrading an application with existing Temporal workflow histories, drain or complete workflows that depend on non-default global activity timeout settings, then deploy the Ruby 4 worker.

### Workflow Versioning Note

Workflow control-flow changes use centralized Temporal patch markers in `ActiveJob::Temporal::Workflows::WorkflowVersioning`. Future changes to workflow branching, persisted workflow state, signal/query/update behavior, helper activity routing, or continue-as-new behavior should add a named patch there and branch through `workflow_patch_enabled?`.

Keep both the old and new workflow paths deployed until in-flight histories that can replay the old path have completed or continued as new. After that drain is verified in Temporal visibility, call `Temporalio::Workflow.deprecate_patch` for the marker in a follow-up deploy, then remove the old branch in a later release.

---

## 3. Migration Strategy

### Dual-Write Approach (Recommended)

1. Deploy dual-write code to both old queue and Temporal
2. Start Temporal workers and verify processing
3. Monitor both systems 24-48 hours
4. Stop writing to old queue
5. Drain old queue completely
6. Remove old infrastructure

**Timeline:** 1-2 weeks (3 days prep, 2-7 days dual-write, 1-3 days drain, 1 day cleanup)

**Testing:** Validate in staging, test failure scenarios, benchmark performance, rehearse rollback.

## 4. Code Changes

### Adapter Configuration

**Before:** `config.active_job.queue_adapter = :sidekiq`
**After:** `config.active_job.queue_adapter = :temporal`

### Retry Configuration

**Before (Sidekiq):**
```ruby
class SendInvoiceJob < ApplicationJob
  sidekiq_options retry: 5, queue: :billing
end
```

**After (ActiveJob DSL):**
```ruby
class SendInvoiceJob < ApplicationJob
  queue_as :billing
  retry_on StandardError, wait: 30.seconds, attempts: 5
end
```

**Key changes:** Replace `sidekiq_options` with `retry_on`/`discard_on` DSL. Specify `wait:` explicitly.

### Known Limitations

#### Algorithmic Wait Strategies

ActiveJob accepts algorithmic wait strategies such as `:exponentially_longer`, `:polynomially_longer`, and custom Procs. activejob-temporal does not execute those functions directly. When `retry_on` uses a Symbol or Proc for `wait:`, the gem uses `default_retry_initial_interval` and lets Temporal apply its configured backoff coefficient.

**ActiveJob example:**
```ruby
class SendInvoiceJob < ApplicationJob
  retry_on StandardError, wait: :exponentially_longer, attempts: 5
end
```

**Temporal behavior with default retry settings:**
- Starts with `default_retry_initial_interval` (`30.seconds`)
- Applies `default_retry_backoff` (`2.0`)
- For `attempts: 5`, allows five total activity attempts with retry delays starting at 30s, 60s, 120s, and 240s

This limitation exists because Temporal RetryPolicy stores deterministic numeric intervals and a fixed backoff coefficient. Arbitrary Ruby wait functions cannot be represented directly in that policy.

Use static wait values for per-job retry timing, and tune `default_retry_backoff` globally when you need a different exponential curve:

```ruby
class SendInvoiceJob < ApplicationJob
  temporal_options start_to_close_timeout: 5.minutes
  retry_on StandardError, wait: 15.seconds, attempts: 5
end
```

With the default backoff coefficient and `attempts: 5`, this allows five total activity attempts with retry delays of 15s, 30s, 60s, and 120s. Use `temporal_options` for activity timeout tuning on long-running jobs, not for custom retry delay functions.

For complete ActiveJob-to-Temporal retry mappings, see the [Retry Policy Guide](retry_policies.md).

### Transaction Safety

activejob-temporal defers enqueue until DB transaction commits (safer than Sidekiq's immediate enqueue). This **may expose existing race conditions** but is generally beneficial.

## 5. Worker Deployment

Temporal workers run as **separate processes** (not part of web app).

```bash
export ACTIVEJOB_TEMPORAL_TARGET=temporal.example.com:7233
export ACTIVEJOB_TEMPORAL_NAMESPACE=production
export ACTIVEJOB_TEMPORAL_TASK_QUEUE=default
export ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=50
export ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=5
bundle exec temporal-worker
```

**Deployment:** Use Kubernetes, systemd, or Docker. Run 2-5 workers per queue for redundancy. Tune `ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES` for activity poll capacity. See [Worker Setup Guide](worker_setup.md) for startup details and [Performance Tuning Guide](performance_tuning.md) for workload-specific recommendations.

## 6. Draining Old Queue

1. Stop enqueueing new jobs: `config.active_job.queue_adapter = :temporal`
2. Monitor old queue depth: `Sidekiq::Queue.new('default').size`
3. Wait for zero depth (hours to days)
4. Check scheduled/retry sets are empty
5. Stop old workers: `kill -TERM $(pgrep -f sidekiq)`
6. Remove old infrastructure

## 7. Rollback Plan

1. Revert adapter: `config.active_job.queue_adapter = :sidekiq`
2. Redeploy application
3. Stop Temporal workers (SIGTERM)
4. Verify old queue infrastructure running
5. Monitor old queue depth returns to normal

**Prevention:** Test rollback in staging, keep old infrastructure running during migration, prepare runbooks.

## 8. Common Gotchas

### 1. Payload Size Limits
**Issue:** 250KB limit (vs Sidekiq's 1MB). **Solution:** Pass IDs instead of objects: `perform(report_id)` not `perform(report)`. Or increase limit: `config.max_payload_size_kb = 500`.

### 2. Idempotency Requirements
**Issue:** Jobs may execute multiple times. **Solution:** Use idempotency keys, DB constraints, check-then-act patterns:
```ruby
return if payment.charged?
PaymentGateway.charge(idempotency_key: Fiber[:aj_temporal_idempotency_key])
```

### 3. Heartbeating for Cancellation
**Issue:** Cancelled jobs don't stop without heartbeating. **Solution:** Add `Temporalio::Activity::Context.current.heartbeat` in long loops (every 10-30 sec).

### 4. Transaction Safety
**Issue:** Jobs enqueue after transaction commits (not immediately). **Solution:** Usually beneficial; exposes existing race conditions. Enqueue outside transactions if needed.

### 5. Search Attributes Not Registered
**Issue:** Temporal UI search fails. **Solution:** Register once per cluster: `tctl admin cluster add-search-attributes --name ajClass --type Keyword ...`

### 6. Workers Not Polling Correct Queue
**Issue:** Jobs never execute. **Solution:** Match worker queue to job: `ACTIVEJOB_TEMPORAL_TASK_QUEUE=billing` and `queue_as :billing`.

## 9. Testing Checklist

**Pre-Migration (Staging):**
- [ ] All jobs execute successfully, scheduled jobs run at correct times
- [ ] Retry/discard logic works, cancellation works with heartbeating
- [ ] Search attributes visible in Temporal UI, payload validation rejects oversized args

**During Migration:**
- [ ] Dual-write to both systems, execution counts match, failure rates comparable
- [ ] Old queue depth decreases, no stuck jobs

**Post-Migration:**
- [ ] Old queue depth zero, error rates acceptable
- [ ] Temporal UI shows expected volume, old queue infrastructure removable

## 10. Resources

**Documentation:** [README](../README.md) | [Comparison Guide](comparison.md) | [Configuration Reference](configuration_reference.md) | [Worker Setup Guide](worker_setup.md) | [Temporal Ruby SDK](https://docs.temporal.io/dev-guide/ruby)

**Community:** [Temporal Slack](https://temporal.io/slack) (#ruby-sdk) | [GitHub Issues](https://github.com/schovi/activejob-temporal/issues) | [Temporal Docs](https://docs.temporal.io/)

**Questions?** Open an issue on [GitHub](https://github.com/schovi/activejob-temporal/issues) or join [Temporal Slack](https://temporal.io/slack).
