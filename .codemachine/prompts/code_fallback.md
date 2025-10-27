# Code Refinement Task

The previous code submission did not pass verification. You must fix the following issues and resubmit your work.

---

## Original Task Description

Create `spec/support/temporal_test_server.rb` with a helper to start and stop a Temporal test server for integration tests. The Temporal Ruby SDK may include a test server (check SDK documentation). If available, wrap it in RSpec `before(:suite)` and `after(:suite)` hooks to start server once before all integration tests and stop after. If SDK doesn't include test server, document manual setup: run `temporal server start-dev` in background before tests, or use Docker Compose. Provide a method `TemporalTestHelper.client` that returns a client connected to the test server. Ensure test server uses a test namespace (e.g., "test"). Write a simple smoke test in `spec/integration/temporal_connection_spec.rb` that verifies connection to test server (e.g., list workflows, should return empty list initially). This ensures test infrastructure is working before writing real integration tests.

---

## Issues Detected

*   **Linting Error:** `bundle exec rubocop` reports `Naming/MemoizedInstanceVariableName` in `spec/support/temporal_test_server.rb:63` because the memoized instance variable name `@original_config` does not match the method `store_original_configuration`.

---

## Best Approach to Fix

Rename the memoized instance variable in `TemporalTestHelper.store_original_configuration` to follow RuboCop's memoized variable naming rule (e.g., change it to `@store_original_configuration`) and update any references accordingly so that `bundle exec rubocop` passes without offenses.
