# Code Refinement Task

The previous code submission did not pass verification. You must fix the following issues and resubmit your work.

---

## Original Task Description

Write integration test in `spec/integration/scheduled_jobs_spec.rb` that tests scheduled job execution using `set(wait:)`. Test flow: (1) Define test job. (2) Enqueue job with delay: `TestJob.set(wait: 5.seconds).perform_later(42)`. (3) Start worker. (4) Assert job does NOT execute immediately (wait 1 second, verify `$test_result` is still nil). (5) Wait for scheduled time (total 6 seconds from enqueue). (6) Assert job executed after delay. (7) Verify workflow used `Workflow.sleep` (check workflow history for timer event using Temporal test client). This test proves durable scheduled execution works.

---

## Issues Detected

*   **Critical Adapter Bug:** Both the new `scheduled_jobs_spec.rb` test AND the existing `enqueue_spec.rb` test are failing with the same error: `Failed to enqueue job TestJob: undefined method '_to_proto' for an instance of Hash`
*   **Root Cause:** In `lib/activejob/temporal/adapter.rb:85`, the `build_payload` method adds a plain Ruby hash from `RetryMapper.for(job.class)` to `payload[:retry_policy]`. This hash is then passed to the workflow, which extracts it in `aj_workflow.rb:51-52` and passes it as `:retry` to the activity options. The Temporal Ruby SDK expects a proper `Temporalio::Client::RetryPolicy` object, not a plain hash.
*   **Test File Structure:** The test file `spec/integration/scheduled_jobs_spec.rb` is correctly structured and follows the pattern from `enqueue_spec.rb`, but it cannot run due to the adapter bug.
*   **Integration Test Cannot Start:** The test enqueue fails immediately with `TestJob.set(wait: 5.seconds).perform_later(42)` returning `false` instead of a job instance, which causes line 29 to fail with `undefined method 'job_id' for false`.

---

## Best Approach to Fix

You MUST fix the adapter's retry policy handling in `lib/activejob/temporal/adapter.rb` and `lib/activejob/temporal/workflows/aj_workflow.rb`:

### Step 1: Fix the Adapter (lib/activejob/temporal/adapter.rb)

Remove the `retry_policy` from the payload. It should NOT be part of the workflow argument. Instead, keep it separate so it can be properly converted before passing to the activity.

**Current buggy code (lines 83-87):**
```ruby
def build_payload(job, scheduled_at: nil)
  payload = ActiveJob::Temporal::Payload.from_job(job, scheduled_at: scheduled_at)
  payload[:retry_policy] = ActiveJob::Temporal::RetryMapper.for(job.class)
  payload
end
```

**Correct approach:**
```ruby
def build_payload(job, scheduled_at: nil)
  ActiveJob::Temporal::Payload.from_job(job, scheduled_at: scheduled_at)
end
```

The retry policy hash should be passed separately to the workflow, or the workflow needs to handle the conversion.

### Step 2: Fix the Workflow Activity Options (lib/activejob/temporal/workflows/aj_workflow.rb)

The workflow's `activity_options` method currently extracts `retry_policy` from the payload and passes it directly as `:retry`. This is incorrect because the Temporal SDK expects a `Temporalio::Client::RetryPolicy` object.

**Current code (lines 47-54):**
```ruby
def activity_options(payload)
  options = {
    start_to_close_timeout: ActiveJob::Temporal.config.default_activity_timeout
  }
  retry_policy = payload[:retry_policy] || payload["retry_policy"]
  options[:retry] = retry_policy if retry_policy
  options
end
```

**Options to fix:**

**Option A (Recommended):** Store retry policy metadata in payload but construct the proper Temporalio retry policy object in the workflow:

```ruby
def activity_options(payload)
  options = {
    start_to_close_timeout: ActiveJob::Temporal.config.default_activity_timeout
  }

  retry_policy_hash = payload[:retry_policy] || payload["retry_policy"]
  if retry_policy_hash
    # Convert hash to proper Temporalio retry policy object
    options[:retry_policy] = build_retry_policy(retry_policy_hash)
  end

  options
end

def build_retry_policy(hash)
  Temporalio::Client::RetryPolicy.new(
    initial_interval: hash[:initial_interval] || hash["initial_interval"],
    backoff_coefficient: hash[:backoff_coefficient] || hash["backoff_coefficient"],
    maximum_attempts: hash[:maximum_attempts] || hash["maximum_attempts"],
    non_retryable_error_types: hash[:non_retryable_error_types] || hash["non_retryable_error_types"] || []
  )
end
```

**Option B:** Remove retry policy from payload entirely and have the workflow look it up directly:

```ruby
def activity_options(payload)
  options = {
    start_to_close_timeout: ActiveJob::Temporal.config.default_activity_timeout
  }

  # Look up job class and get retry policy
  job_class_name = payload[:job_class] || payload["job_class"]
  if job_class_name
    job_class = Object.const_get(job_class_name)
    retry_hash = ActiveJob::Temporal::RetryMapper.for(job_class)
    options[:retry_policy] = build_retry_policy(retry_hash)
  end

  options
end
```

### Step 3: Verify Tests Pass

After fixing the adapter and workflow:

1. Run `bundle exec rspec spec/integration/enqueue_spec.rb` to verify the existing test passes
2. Run `bundle exec rspec spec/integration/scheduled_jobs_spec.rb` to verify the new test passes
3. Ensure both tests show proper workflow execution and timer events

### Step 4: Address Any Additional Issues

If there are other issues after fixing the retry policy bug, address them systematically:
- Check if the Temporal SDK method is `retry_policy` or just `retry`
- Verify the correct parameter names for RetryPolicy constructor
- Check the Temporal Ruby SDK documentation if needed

---

## Additional Context

- The test file structure in `spec/integration/scheduled_jobs_spec.rb` is correct
- Both integration tests require the Temporal server to be running with the "test" namespace
- The docker-compose.yml is present and the test namespace has been created
- The fix should allow BOTH `enqueue_spec.rb` AND `scheduled_jobs_spec.rb` to pass
