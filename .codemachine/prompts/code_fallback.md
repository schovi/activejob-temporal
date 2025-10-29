# Code Refinement Task

The previous code submission did not pass verification. You must fix the following issues and resubmit your work.

---

## Original Task Description

Write integration test in `spec/integration/retries_spec.rb` that tests retry behavior for transient errors. Test flow: (1) Define a job that fails with `raise StandardError` on first execution, then succeeds on retry (use a counter: `$attempt_count ||= 0; $attempt_count += 1; raise StandardError if $attempt_count == 1; $test_result = 'success'`). (2) Configure job with `retry_on StandardError, wait: 1, attempts: 3`. (3) Enqueue job. (4) Start worker. (5) Wait for job to execute, fail, retry, and succeed. (6) Assert `$test_result == 'success'`. (7) Verify workflow history shows activity retry (check for activity failure + retry events). This test proves retry_on mapping works and Temporal retries activities.

---

## Issues Detected

*   **Critical: Test File Not Created:** The file `spec/integration/retries_spec.rb` does not exist. The task was not implemented at all.
*   **Critical: Test Job Not Created:** The test job class with retry behavior was not added to `spec/fixtures/sample_jobs.rb`.
*   **Linting Errors in aj_runner_activity.rb:** There are indentation and alignment errors in `lib/activejob/temporal/activities/aj_runner_activity.rb` at lines 88-95:
    - Line 89: Indentation is using 1 space instead of 2 spaces
    - Line 90: `elsif` is not aligned with `if`
    - Line 93: `else` is not aligned with `if`
    - Line 95: `end` is not aligned with `if`

---

## Best Approach to Fix

### Step 1: Fix Linting Errors in aj_runner_activity.rb

Fix the indentation in the `set_idempotency_key` method at lines 87-96. The corrected code should be:

```ruby
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

### Step 2: Add Test Job to sample_jobs.rb

Add the following job class to `spec/fixtures/sample_jobs.rb` at the end of the file:

```ruby
class RetryTestJob < ActiveJob::Base
  retry_on StandardError, wait: 1, attempts: 3

  queue_as :default

  def perform
    $attempt_count ||= 0
    $attempt_count += 1
    raise StandardError, "Transient error" if $attempt_count == 1
    $test_result = "success"
  end
end
```

### Step 3: Create the Integration Test File

Create the file `spec/integration/retries_spec.rb` with the following content:

```ruby
# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

RSpec.describe "ActiveJob Temporal retry behavior", :integration do
  let(:client) { TemporalTestHelper.client }

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal
    $attempt_count = 0
    $test_result = nil

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    stop_worker(@worker_thread)
    $attempt_count = 0
    $test_result = nil
  end

  it "retries transient errors according to retry_on configuration" do
    # Start worker first
    @worker_thread = start_worker

    # Enqueue the job
    job = RetryTestJob.perform_later
    workflow_id = "ajwf:RetryTestJob:#{job.job_id}"

    # Wait for job to complete (with retries) - max 10 seconds
    wait_for_result("success")

    # Assert final result
    expect($test_result).to eq("success")

    # Assert job executed exactly twice (failed once, succeeded once)
    expect($attempt_count).to eq(2)

    # Verify workflow completed successfully
    description = client.workflow_handle(workflow_id).describe
    expect(description.status.name).to eq("COMPLETED")

    # Verify workflow history shows activity retry events
    history = client.workflow_handle(workflow_id).fetch_history
    events = history.events

    # Look for activity failure event (indicates retry occurred)
    activity_failed_events = events.select { |e| e.type == :EVENT_TYPE_ACTIVITY_TASK_FAILED }
    expect(activity_failed_events.size).to be >= 1

    # Look for multiple activity started events (indicates retries)
    activity_started_events = events.select { |e| e.type == :EVENT_TYPE_ACTIVITY_TASK_STARTED }
    expect(activity_started_events.size).to be >= 2
  end

  private

  def start_worker
    Thread.new do
      worker = Temporalio::Worker.new(
        client: client,
        task_queue: "default",
        workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
        activities: [ActiveJob::Temporal::Activities::AjRunnerActivity]
      )
      worker.run
    end
  end

  def stop_worker(thread)
    return unless thread&.alive?

    thread.kill
    thread.join(5)
  end

  def wait_for_result(expected)
    Timeout.timeout(10) do
      loop do
        break if $test_result == expected
        sleep 0.1
      end
    end
  end
end
```

### Step 4: Run Tests to Verify

After implementing the fixes:

1. Run `bundle exec rubocop` to verify linting errors are fixed
2. Run `bundle exec rspec spec/integration/retries_spec.rb` to verify the test passes
3. Ensure the test properly demonstrates retry behavior with activity failures

---

## Key Requirements to Remember

- The job MUST fail exactly once (when `$attempt_count == 1`), then succeed on retry
- The test MUST use global variables (`$attempt_count` and `$test_result`) because job instances are recreated on retry
- The test MUST verify workflow history contains activity failure events
- The test MUST verify the final attempt count is 2 (initial failure + successful retry)
- The `wait: 1` configuration means 1 second between retries, keeping test execution fast
- The test MUST be isolated (reset global variables in setup and cleanup)
