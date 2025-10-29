# Code Refinement Task

The previous code submission did not pass verification. You must fix the following issues and resubmit your work.

---

## Original Task Description

Run `rake spec:integration` (or `rake spec`) to execute all integration tests written in Iteration 4. Verify all tests pass. Generate coverage report and ensure overall gem coverage (unit + integration) is >= 90%. If coverage is below target, identify gaps and write additional unit or integration tests.

**Acceptance Criteria:**
- `rake spec:integration` (or `rake spec`) exits with status 0 (all integration tests pass)
- SimpleCov report shows >= 90% overall code coverage (lib/ directory)
- Coverage report includes both unit and integration test coverage
- All integration tests run successfully with Temporal test server
- No flaky tests (tests pass consistently on multiple runs)

---

## Issues Detected

**Coverage Status:** ✅ **PASSED** - Coverage is at 97.94% (428/437 lines), which exceeds the 90% target.

**Test Failures:** ❌ **FAILED** - 5 integration tests are failing due to configuration leakage between unit and integration tests.

### Specific Issues

1. **Configuration Pollution from Unit Tests**
   - The unit test `spec/unit/client_spec.rb` (specifically the "wraps connection errors" test on line 122-133) sets the Temporal configuration to `target: "1.2.3.4:7233"` and `namespace: "production"`.
   - This configuration change persists after the unit test completes because the `before` block only resets `@client` and `@config` to `nil`, but doesn't restore the original configuration values.
   - When integration tests run afterward (due to random test ordering), they try to connect to `1.2.3.4:7233` instead of the test server at `127.0.0.1:7233`.
   - This causes integration tests to fail with connection timeout errors.

2. **RSpec Mock Leakage (Already Fixed)**
   - The `let(:client)` memoization was causing RSpec doubles to leak between tests.
   - This has been fixed by converting `let(:client)` to a regular `def client` method in all integration test files.

### Failing Tests

All 5 failing tests are integration tests that cannot connect to the Temporal server:
- `ActiveJob Temporal retry behavior` > "retries transient errors according to retry_on configuration"
- `ActiveJob Temporal retry behavior` > "discards non-retryable errors according to discard_on configuration"
- `ActiveJob Temporal cancellation` > "cancels a long-running job via heartbeat mechanism"
- `ActiveJob Temporal scheduled jobs` > "executes a scheduled job after the specified delay"
- `ActiveJob Temporal enqueue` > "executes an enqueued job immediately via Temporal"

All failures show the same error:
```
Unable to connect to Temporal at 1.2.3.4:7233 (namespace: production)
```

---

## Best Approach to Fix

You MUST modify `spec/unit/client_spec.rb` to properly save and restore the original Temporal configuration around each test.

### Required Changes

**File: `spec/unit/client_spec.rb`**

**Current Code (Lines 10-14):**
```ruby
before do
  described_class.instance_variable_set(:@client, nil)
  described_class.instance_variable_set(:@config, nil)
  stub_const("Temporalio::Client", class_double("Temporalio::Client"))
end
```

**Required Fix:**

Add a new `around` block that saves and restores the configuration state around each test:

```ruby
around do |example|
  # Save original configuration
  original_client = described_class.instance_variable_get(:@client)
  original_config = described_class.instance_variable_get(:@config)
  original_target = described_class.config.target
  original_namespace = described_class.config.namespace

  # Reset for test
  described_class.instance_variable_set(:@client, nil)
  described_class.instance_variable_set(:@config, nil)
  stub_const("Temporalio::Client", class_double("Temporalio::Client"))

  example.run
ensure
  # Restore original configuration
  described_class.instance_variable_set(:@client, original_client)
  described_class.instance_variable_set(:@config, original_config)
  if original_config
    described_class.configure do |config|
      config.target = original_target
      config.namespace = original_namespace
    end
  end
end
```

**Important Notes:**
1. Remove the existing `before` block (lines 10-14) and replace it with the `around` block above
2. The existing `around` block for TLS environment variables (lines 16-32) should remain unchanged
3. You will have TWO `around` blocks in the test file - one for configuration state and one for TLS env vars
4. The configuration restoration in the `ensure` block is critical - this prevents configuration pollution from leaking into other tests

### Why This Fix Works

- The `around` block executes setup before the test and cleanup after the test in the `ensure` block
- By saving the original configuration values and restoring them in `ensure`, we guarantee that any configuration changes made during a test are reverted
- This prevents the "1.2.3.4:7233" configuration from the unit test from leaking into integration tests
- Integration tests will be able to use the test server configuration set by `TemporalTestHelper`

### After Making the Fix

1. Run the complete test suite: `bundle exec rake spec`
2. Verify all 115 tests pass (108 unit + 7 integration)
3. Verify coverage remains >= 90% (currently at 97.94%)
4. Run tests 3 times to check for flakiness: `for i in {1..3}; do bundle exec rake spec || break; done`
