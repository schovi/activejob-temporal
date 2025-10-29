# Migration Guide: From Traditional Job Queues to activejob-temporal

This guide provides practical, step-by-step instructions for migrating from traditional job queue systems (Sidekiq, Resque, Delayed Job) to activejob-temporal backed by Temporal's durable execution engine.

---

## 1. Why Migrate

Temporal provides several advantages over traditional job queue systems:

- **Durable execution:** Jobs survive infrastructure failures, deployments, and process restarts without external queue storage
- **Superior observability:** Real-time job monitoring and debugging via Temporal UI with powerful search capabilities
- **Built-in fault tolerance:** Battle-tested retry policies and automatic transient failure handling
- **Simplified operations:** No separate Redis, PostgreSQL, or queue infrastructure to maintain—Temporal handles all persistence and coordination
- **Advanced features:** Job cancellation, workflow orchestration, and long-running process support

**Best suited for:**
- Applications requiring high reliability and audit trails
- Complex job orchestration and coordination scenarios
- Teams already using Temporal for other workflows
- Projects seeking to reduce operational complexity by consolidating infrastructure

---

## 2. Prerequisites

Before starting migration:

- **Temporal cluster access:** Self-hosted Temporal server or Temporal Cloud account
- **Ruby >= 3.2** and **Rails >= 6.1** (ActiveJob 6.1+)
- **Gem installation:** Add `gem "activejob-temporal"` to your Gemfile and run `bundle install`
- **Search attributes registered:** One-time cluster setup (see [README Quick Start](../README.md#step-3-register-search-attributes-one-time-setup))
- **Understanding of your current job infrastructure:** Identify all job classes, queues, retry configurations, and deployment topology

**Reference documentation:**
- [README: Quick Start](../README.md#quick-start)
- [Configuration Reference](configuration_reference.md)
- [Worker Setup Guide](worker_setup.md)

---

## 3. Migration Strategy

### Dual-Write Approach (Recommended)

The safest migration path is to temporarily write jobs to both old and new systems:

1. **Deploy dual-write code** that enqueues jobs to both your existing queue (Sidekiq/Resque) and Temporal
2. **Start Temporal workers** and verify they process jobs correctly
3. **Monitor both systems** for 24-48 hours to ensure parity and catch edge cases
4. **Stop writing to old queue** by flipping a feature flag or deploying new code
5. **Drain old queue completely** before removing old workers
6. **Remove old queue infrastructure** once verified no jobs remain

### Gradual Migration Timeline

| Phase | Duration | Actions |
| --- | --- | --- |
| **Preparation** | 1-3 days | Install gem, configure Temporal, register search attributes, test in staging |
| **Dual-Write** | 2-7 days | Deploy dual-write code, monitor both systems, compare job execution |
| **Cutover** | 1 day | Stop enqueueing to old queue, monitor job backlog |
| **Drain** | 1-3 days | Wait for old queue to reach zero depth, verify no stragglers |
| **Cleanup** | 1 day | Remove old workers, old adapter code, old queue infrastructure |

**Total estimated time:** 1-2 weeks for a safe, monitored migration.

### Testing Strategy

Before production cutover:

- **Staging environment migration:** Replicate the migration process fully in staging
- **Job execution validation:** Verify all job types execute successfully with expected behavior
- **Failure scenario testing:** Simulate worker crashes, network failures, and transient errors to confirm retry logic works
- **Performance benchmarking:** Compare job throughput and latency between old and new systems
- **Rollback rehearsal:** Practice reverting to the old queue system to ensure you can rollback quickly if needed

---

## 4. Code Changes

### Adapter Configuration

**Before (Sidekiq):**
```ruby
# config/application.rb
config.active_job.queue_adapter = :sidekiq
```

**After (activejob-temporal):**
```ruby
# config/application.rb
config.active_job.queue_adapter = :temporal
```

**Dual-Write Implementation (Transition Period):**
```ruby
# config/application.rb
config.active_job.queue_adapter = :sidekiq  # Primary adapter during transition

# config/initializers/activejob_temporal.rb
ActiveJob::Temporal.configure do |config|
  config.target = ENV.fetch("TEMPORAL_TARGET", "localhost:7233")
  config.namespace = ENV.fetch("TEMPORAL_NAMESPACE", "default")
  # ... other configuration
end

# app/jobs/application_job.rb
class ApplicationJob < ActiveJob::Base
  after_enqueue do |job|
    # Dual-write: also enqueue to Temporal if feature flag enabled
    if ENV["ENABLE_TEMPORAL_DUAL_WRITE"] == "true"
      ActiveJob::Temporal.client.start_workflow(
        "ajwf:#{job.class.name}:#{job.job_id}",
        # ... workflow parameters (see adapter implementation for details)
      )
    end
  end
end
```

> **Note:** The dual-write example above is simplified. For production use, consider using a feature flag service or implementing retry logic for the Temporal enqueue.

### Retry Configuration Migration

**Before (Sidekiq-specific options):**
```ruby
class SendInvoiceJob < ApplicationJob
  sidekiq_options retry: 5, queue: :billing

  def perform(invoice_id)
    # Job logic
  end
end
```

**After (ActiveJob standard DSL):**
```ruby
class SendInvoiceJob < ApplicationJob
  queue_as :billing

  retry_on StandardError, wait: 30.seconds, attempts: 5

  def perform(invoice_id)
    # Job logic (unchanged)
  end
end
```

**Key differences:**
- Replace `sidekiq_options retry:` with `retry_on StandardError, attempts:`
- Explicitly specify `wait:` for initial retry interval (Sidekiq defaults to exponential backoff starting at 15 seconds)
- Use `discard_on` for non-retryable errors instead of `sidekiq_retry_in { |count, exception| nil }`

### Transaction Safety (Behavioral Change)

activejob-temporal implements `enqueue_after_transaction_commit? = true`, which means jobs are NOT enqueued until the current database transaction commits.

**Sidekiq behavior (unsafe by default):**
```ruby
ActiveRecord::Base.transaction do
  invoice = Invoice.create!(amount: 100)
  SendInvoiceJob.perform_later(invoice.id)  # Enqueued IMMEDIATELY, before commit!
end
# If transaction rolls back, job may fail because invoice doesn't exist yet
```

**activejob-temporal behavior (safe):**
```ruby
ActiveRecord::Base.transaction do
  invoice = Invoice.create!(amount: 100)
  SendInvoiceJob.perform_later(invoice.id)  # Enqueued AFTER transaction commits
end
# Job only executes if transaction succeeds
```

**Migration impact:**
- This change **may expose existing race condition bugs** in your application where jobs were enqueued but the transaction rolled back
- Most applications will benefit from this safer behavior
- If you relied on immediate enqueuing, you may need to refactor to enqueue jobs outside transactions

---

## 5. Worker Deployment

Traditional queue systems (Sidekiq, Resque) often run workers as part of the web application process. Temporal workers **must be separate processes** that poll task queues.

### Starting Temporal Workers

```bash
# Environment variables
export TEMPORAL_TARGET=temporal.example.com:7233
export TEMPORAL_NAMESPACE=production
export AJ_TEMPORAL_WORKER_QUEUE=default
export AJ_TEMPORAL_MAX_ACT=50  # Concurrent activity limit

# Start worker
bin/temporal-worker
```

### Production Deployment Options

**Option 1: Kubernetes Deployment**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: temporal-worker-default
spec:
  replicas: 3  # Multiple workers for redundancy
  template:
    spec:
      containers:
      - name: worker
        image: your-app:latest
        command: ["bin/temporal-worker"]
        env:
        - name: TEMPORAL_TARGET
          value: "temporal.example.com:7233"
        - name: TEMPORAL_NAMESPACE
          value: "production"
        - name: AJ_TEMPORAL_WORKER_QUEUE
          value: "default"
        - name: AJ_TEMPORAL_MAX_ACT
          value: "50"
```

**Option 2: Systemd Service**
```ini
# /etc/systemd/system/temporal-worker@.service
[Unit]
Description=Temporal Worker for Queue %i
After=network.target

[Service]
Type=simple
User=deploy
WorkingDirectory=/var/www/app
Environment="TEMPORAL_TARGET=temporal.example.com:7233"
Environment="TEMPORAL_NAMESPACE=production"
Environment="AJ_TEMPORAL_WORKER_QUEUE=%i"
Environment="AJ_TEMPORAL_MAX_ACT=50"
ExecStart=/var/www/app/bin/temporal-worker
Restart=always

[Install]
WantedBy=multi-user.target
```

Start with: `sudo systemctl start temporal-worker@billing temporal-worker@default`

### Scaling Considerations

- **Multiple workers per queue:** Run 2-5 workers per queue for redundancy (Temporal load-balances automatically)
- **Tune concurrency:** Set `AJ_TEMPORAL_MAX_ACT` based on job workload (CPU-bound: lower; I/O-bound: higher)
- **Graceful shutdown:** Workers finish in-flight activities before exiting on SIGTERM (see [Worker Setup Guide](worker_setup.md))

**Reference:** [Worker Setup Guide](worker_setup.md)

---

## 6. Draining Old Queue

Before removing old queue infrastructure, ensure all jobs have completed:

### Step-by-Step Draining Process

1. **Stop enqueueing new jobs to old queue:**
   ```ruby
   # Flip feature flag or deploy code with only Temporal adapter
   config.active_job.queue_adapter = :temporal
   ```

2. **Monitor old queue depth:**
   ```bash
   # Sidekiq
   bundle exec rails runner "puts Sidekiq::Queue.new('default').size"

   # Resque
   bundle exec rails runner "puts Resque.size('default')"
   ```

3. **Wait for queue depth to reach zero:**
   - Check queue depth every hour
   - Typical drain time: a few hours to 2-3 days depending on job volume and scheduled jobs

4. **Verify no scheduled/retry jobs remain:**
   ```bash
   # Sidekiq scheduled set
   bundle exec rails runner "puts Sidekiq::ScheduledSet.new.size"

   # Sidekiq retry set
   bundle exec rails runner "puts Sidekiq::RetrySet.new.size"
   ```

5. **Check dead letter queue:**
   - Review any jobs in the dead letter queue (Sidekiq Dead Set, Resque Failed)
   - Manually re-enqueue critical failed jobs to Temporal or resolve issues

6. **Stop old workers:**
   ```bash
   # Stop Sidekiq workers gracefully
   kill -TERM $(pgrep -f sidekiq)

   # Wait for workers to finish in-flight jobs (can take minutes)
   ```

7. **Remove old queue infrastructure** (Redis, PostgreSQL queue tables, etc.) once verified empty

---

## 7. Rollback Plan

If issues arise during migration, you must be able to revert quickly:

### Rollback Steps

1. **Revert adapter configuration:**
   ```ruby
   # config/application.rb
   config.active_job.queue_adapter = :sidekiq  # Or previous adapter
   ```

2. **Redeploy application** with old adapter

3. **Stop Temporal workers** (graceful shutdown via SIGTERM)

4. **Verify old queue infrastructure** is still running (Redis, Sidekiq workers, etc.)

5. **Monitor old queue** to confirm jobs are processing again

### What to Monitor During Rollback

- Old queue depth returns to normal processing rate
- No jobs stuck in old queue's retry or dead sets
- Application logs show jobs enqueuing to old adapter
- Error rates return to baseline

### Prevention

- **Test rollback in staging** before production migration
- **Keep old infrastructure running** during the entire dual-write and drain period
- **Have runbooks ready** with exact rollback commands

---

## 8. Common Gotchas

### Gotcha 1: Payload Size Limits

**Issue:** activejob-temporal defaults to **250KB payload limit** (configurable), while Sidekiq defaults to **1MB**.

**Symptoms:**
- `ActiveJob::SerializationError` raised when enqueueing jobs
- Jobs that previously worked with Sidekiq fail with activejob-temporal

**Solution:**
```ruby
# Option 1: Increase limit (not recommended beyond 500KB)
ActiveJob::Temporal.configure do |config|
  config.max_payload_size_kb = 500
end

# Option 2: Refactor to pass references instead of large objects (recommended)
class SendReportJob < ApplicationJob
  def perform(report_id)  # Pass ID instead of entire Report object
    report = Report.find(report_id)
    # Generate and send report
  end
end
```

**Why smaller limits?** Temporal stores workflow history in its database. Large payloads degrade performance and increase storage costs.

### Gotcha 2: Idempotency Requirements

**Issue:** Temporal guarantees **at-least-once execution**, meaning jobs MAY execute multiple times (e.g., during worker restarts or network partitions).

**Impact:** Non-idempotent jobs may produce duplicate side effects (double-charging customers, sending duplicate emails, etc.).

**Solution:**
```ruby
class ChargeCustomerJob < ApplicationJob
  def perform(payment_id)
    payment = Payment.find(payment_id)

    # Use idempotency key to prevent duplicate charges
    idempotency_key = Thread.current[:aj_temporal_idempotency_key]

    return if payment.charged?  # Already processed

    PaymentGateway.charge(
      amount: payment.amount,
      idempotency_key: idempotency_key  # Prevents duplicate charges
    )

    payment.update!(charged: true)
  end
end
```

**Best practices:**
- Use database uniqueness constraints
- Check-then-act patterns with locks
- Idempotency keys from `Thread.current[:aj_temporal_idempotency_key]` (contains workflow ID)

### Gotcha 3: Heartbeating for Cancellation

**Issue:** Jobs can be cancelled via `ActiveJob::Temporal.cancel(JobClass, job_id)`, but cancellation only takes effect when the activity checks for cancellation signals.

**Impact:** Without heartbeating, cancelled jobs run to completion and waste resources.

**Solution:**
```ruby
class LongRunningJob < ApplicationJob
  def perform
    1000.times do |i|
      # Heartbeat every iteration to check for cancellation
      Temporalio::Activity::Context.current.heartbeat

      process_chunk(i)
      sleep 1
    end
  end
end
```

**When to heartbeat:**
- Every loop iteration for long-running loops
- Periodically (every 10-30 seconds) for I/O-bound jobs
- Not needed for short jobs (< 1 minute)

### Gotcha 4: Transaction Safety Changes

**Issue:** activejob-temporal defers job enqueue until database transaction commits, which differs from Sidekiq's default behavior.

**Symptoms:**
- Jobs execute later than expected (after transaction commits, not immediately)
- Existing race condition bugs may surface (e.g., jobs failing because data isn't committed yet)

**Solution:** This is generally a **beneficial change**. If issues arise:
```ruby
# If you MUST enqueue before commit (not recommended), enqueue outside transaction
invoice = Invoice.create!(amount: 100)
ActiveRecord::Base.transaction do
  # Other database operations
end
SendInvoiceJob.perform_later(invoice.id)  # Outside transaction
```

### Gotcha 5: Search Attributes Not Registered

**Issue:** Temporal UI search returns no results, or workflows don't appear when filtering.

**Symptoms:**
- Queries like `ajQueue = "billing"` return no workflows
- Search attributes appear empty in Temporal UI

**Solution:**
```bash
# Register search attributes once per cluster
tctl admin cluster add-search-attributes \
  --name ajClass --type Keyword \
  --name ajQueue --type Keyword \
  --name ajJobId --type Keyword \
  --name ajEnqueuedAt --type Datetime \
  --name ajTenantId --type Keyword
```

**Note:** Registration is a **one-time setup** and only affects new workflows. Existing workflows won't have search attributes retroactively added.

### Gotcha 6: Workers Not Polling Correct Queue

**Issue:** Jobs enqueue successfully but never execute.

**Symptoms:**
- Workflows appear in Temporal UI with "Running" status indefinitely
- No worker logs show job execution

**Solution:**
```bash
# Verify worker queue matches job queue
AJ_TEMPORAL_WORKER_QUEUE=billing bin/temporal-worker

# Check job class queue configuration
class SendInvoiceJob < ApplicationJob
  queue_as :billing  # Must match worker queue
end
```

---

## 9. Testing Checklist

### Pre-Migration Tests (Staging)

- [ ] All job classes execute successfully with Temporal adapter
- [ ] Scheduled jobs execute at correct times (`set(wait:)` and `set(wait_until:)`)
- [ ] Retry logic works as expected (`retry_on` declarations)
- [ ] Discard logic prevents retries (`discard_on` declarations)
- [ ] Job cancellation works for long-running jobs (with heartbeating)
- [ ] Search attributes appear correctly in Temporal UI
- [ ] Workers restart gracefully without losing in-flight jobs
- [ ] Payload size validation rejects oversized payloads

### During Migration Monitoring

- [ ] Dual-write enqueues jobs to both old and new systems
- [ ] Job execution count matches between old and new systems
- [ ] Job failure rates are comparable
- [ ] Temporal workers show healthy metrics (no crashes, memory leaks)
- [ ] Old queue depth decreases as expected
- [ ] No jobs stuck in old queue's retry or dead sets

### Post-Migration Verification

- [ ] All jobs execute only via Temporal (old queue depth is zero)
- [ ] Error rates and job latency are within acceptable ranges
- [ ] Temporal UI shows expected job volume and success rates
- [ ] Application logs show no Sidekiq/Resque references
- [ ] Old queue infrastructure can be safely removed

---

## 10. Resources

### Documentation

- [README: Quick Start](../README.md#quick-start)
- [Configuration Reference](configuration_reference.md)
- [Worker Setup Guide](worker_setup.md)
- [Temporal Ruby SDK Documentation](https://docs.temporal.io/dev-guide/ruby)

### Community Support

- [Temporal Community Slack](https://temporal.io/slack) — Join the `#ruby-sdk` channel
- [GitHub Issues](https://github.com/temporalio/activejob-temporal/issues) — Report bugs and request features
- [Temporal Documentation](https://docs.temporal.io/) — Core concepts and best practices

### Migration Assistance

- [Temporal Professional Services](https://temporal.io/services) — Expert guidance for complex migrations
- [Temporal Community Forum](https://community.temporal.io/) — Ask questions and share experiences

---

**Questions or feedback?** Open an issue on [GitHub](https://github.com/temporalio/activejob-temporal/issues) or join the [Temporal Slack community](https://temporal.io/slack).
