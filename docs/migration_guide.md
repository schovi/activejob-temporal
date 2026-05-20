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

Ruby 4 support requires Temporal Ruby SDK 1.4.1+, which rejects process configuration reads from workflow code. New workflows serialize global activity timeout defaults into the workflow payload at enqueue time. Before upgrading an application with existing Temporal workflow histories, drain or complete workflows that depend on non-default global activity timeout settings, then deploy the Ruby 4 worker.

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

### Transaction Safety

activejob-temporal defers enqueue until DB transaction commits (safer than Sidekiq's immediate enqueue). This **may expose existing race conditions** but is generally beneficial.

## 5. Worker Deployment

Temporal workers run as **separate processes** (not part of web app).

```bash
export TEMPORAL_TARGET=temporal.example.com:7233
export TEMPORAL_NAMESPACE=production
export AJ_TEMPORAL_WORKER_QUEUE=default
export AJ_TEMPORAL_MAX_ACT=50
bin/temporal-worker
```

**Deployment:** Use Kubernetes, systemd, or Docker. Run 2-5 workers per queue for redundancy. Tune `AJ_TEMPORAL_MAX_ACT` for concurrency. See [Worker Setup Guide](worker_setup.md) for full details.

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
PaymentGateway.charge(idempotency_key: Thread.current[:aj_temporal_idempotency_key])
```

### 3. Heartbeating for Cancellation
**Issue:** Cancelled jobs don't stop without heartbeating. **Solution:** Add `Temporalio::Activity::Context.current.heartbeat` in long loops (every 10-30 sec).

### 4. Transaction Safety
**Issue:** Jobs enqueue after transaction commits (not immediately). **Solution:** Usually beneficial; exposes existing race conditions. Enqueue outside transactions if needed.

### 5. Search Attributes Not Registered
**Issue:** Temporal UI search fails. **Solution:** Register once per cluster: `tctl admin cluster add-search-attributes --name ajClass --type Keyword ...`

### 6. Workers Not Polling Correct Queue
**Issue:** Jobs never execute. **Solution:** Match worker queue to job: `AJ_TEMPORAL_WORKER_QUEUE=billing` and `queue_as :billing`.

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

**Documentation:** [README](../README.md) | [Configuration Reference](configuration_reference.md) | [Worker Setup Guide](worker_setup.md) | [Temporal Ruby SDK](https://docs.temporal.io/dev-guide/ruby)

**Community:** [Temporal Slack](https://temporal.io/slack) (#ruby-sdk) | [GitHub Issues](https://github.com/temporalio/activejob-temporal/issues) | [Temporal Docs](https://docs.temporal.io/)

**Questions?** Open an issue on [GitHub](https://github.com/temporalio/activejob-temporal/issues) or join [Temporal Slack](https://temporal.io/slack).
