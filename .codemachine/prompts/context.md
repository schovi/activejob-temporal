# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I4.T2",
  "iteration_id": "I4",
  "iteration_goal": "Implement the Temporal worker bootstrap script, write comprehensive integration tests with a real Temporal test server, and validate end-to-end functionality (enqueue → workflow → activity → job execution).",
  "description": "Create `spec/support/temporal_test_server.rb` with a helper to start and stop a Temporal test server for integration tests. The Temporal Ruby SDK may include a test server (check SDK documentation). If available, wrap it in RSpec `before(:suite)` and `after(:suite)` hooks to start server once before all integration tests and stop after. If SDK doesn't include test server, document manual setup: run `temporal server start-dev` in background before tests, or use Docker Compose. Provide a method `TemporalTestHelper.client` that returns a client connected to the test server. Ensure test server uses a test namespace (e.g., \"test\"). Write a simple smoke test in `spec/integration/temporal_connection_spec.rb` that verifies connection to test server (e.g., list workflows, should return empty list initially). This ensures test infrastructure is working before writing real integration tests.",
  "agent_type_hint": "BackendAgent",
  "inputs": "temporalio Ruby testing documentation, Temporal test server documentation, RSpec setup patterns",
  "target_files": [
    "spec/support/temporal_test_server.rb",
    "spec/integration/temporal_connection_spec.rb",
    "spec/spec_helper.rb"
  ],
  "input_files": [
    "spec/spec_helper.rb"
  ],
  "deliverables": "Working Temporal test server setup, passing smoke test for connection",
  "acceptance_criteria": "`spec/support/temporal_test_server.rb` exists with `TemporalTestHelper` module; Helper starts Temporal test server (or documents manual setup); Helper provides `TemporalTestHelper.client` method returning connected client; Test server uses \"test\" namespace; `spec/spec_helper.rb` requires temporal_test_server helper; Smoke test in `spec/integration/temporal_connection_spec.rb` connects to test server and lists workflows (empty list expected); `rake spec` passes for temporal_connection_spec.rb; Manual verification: Running `rake spec:integration` starts test server and runs smoke test",
  "dependencies": [
    "I1.T4"
  ],
  "parallelizable": true,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: Testing Levels (from 03_Verification_and_Glossary.md)

The activejob-temporal gem employs a comprehensive, multi-layered testing strategy to ensure correctness, reliability, and production readiness.

**Unit Testing (RSpec)**

- **Scope**: Individual classes and modules in isolation
- **Location**: `spec/unit/`
- **Coverage Target**: >= 90% code coverage for each module
- **Mocking Strategy**: Mock external dependencies (Temporal client, workflow/activity execution, job classes) to isolate logic
- **Tools**: RSpec 3.x, SimpleCov for coverage

**Integration Testing (RSpec with Temporal Test Server)**

- **Scope**: End-to-end workflows with real Temporal server
- **Location**: `spec/integration/`
- **Environment**: Temporal test server (in-memory or Docker-based)
- **Coverage Target**: >= 90% overall coverage (combined with unit tests)
- **Key Scenarios**:
  - **Immediate Job Execution**: Enqueue → Workflow → Activity → Job performs → Completion
  - **Scheduled Job Execution**: Enqueue with `set(wait:)` → Workflow sleeps → Activity executes after delay
  - **Retry Behavior**: Job fails with retryable exception → Temporal retries activity per policy → Eventual success
  - **Discard Behavior**: Job fails with non-retryable exception → Workflow fails immediately without retry
  - **Cancellation**: Enqueue → Job starts → Cancel called → Activity aborts via heartbeat → Workflow cancelled
  - **Search Attributes**: Enqueue → Workflow completes → Query Temporal for attributes → Verify presence and values
- **Tools**: RSpec 3.x, Temporal test server helper, SimpleCov

### Context: CI/CD Strategy (from 03_Verification_and_Glossary.md)

**Continuous Integration (GitHub Actions)**

- **Jobs**:
  1. **Lint**: Run Rubocop (`bundle exec rubocop`), fail build on offenses
  2. **Unit Tests**: Run RSpec unit tests (`bundle exec rake spec:unit`), fail on test failures
  3. **Integration Tests**: Run RSpec integration tests with Temporal test server (`bundle exec rake spec:integration`), fail on test failures
  4. **Coverage Check**: Upload coverage report to Codecov (optional), enforce >= 90% threshold
  5. **YARD Docs**: Generate YARD docs (`bundle exec rake yard`), fail on warnings
  6. **Gem Build**: Build gem (`gem build activejob-temporal.gemspec`), fail if build errors

This indicates that the CI system expects separate `rake spec:unit` and `rake spec:integration` tasks to exist.

### Context: Testing Framework Design (from 06_Rationale_and_Future.md)

**Areas for Deeper Dive - Testing Framework**

Design a testing framework tailored for activejob-temporal that simplifies writing tests for Temporal-backed jobs:

- **Unit testing helpers**: Stub Temporal workflow execution
- **Integration tests with Temporal test server** (slow)
- **Time travel**: `Temporal.time_warp(5.minutes)` in tests (future consideration)
- **Workflow history assertions**: Verify sleep/activity calls
- Study Temporal Go/Java SDK test frameworks
- Document testing best practices

This indicates that integration tests with a real Temporal server are expected to be slower than unit tests, so separating them makes sense.

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `spec/spec_helper.rb`
    *   **Summary:** This is the main RSpec configuration file. It sets up SimpleCov for code coverage, requires bundler/setup and activejob/temporal, and configures RSpec expectations and mocking.
    *   **Current State:** The file does NOT load support files from `spec/support/`. It only requires the gem itself.
    *   **Recommendation:** You MUST modify this file to require the new `spec/support/temporal_test_server.rb` helper. Add `require_relative "support/temporal_test_server"` after the existing requires (around line 10, after `require "activejob/temporal"`).
    *   **Alternative:** You could use RSpec's auto-loading of support files by adding `Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }`, but explicit requiring is simpler for a single file.

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** This is the main module file that defines the `ActiveJob::Temporal` module, Configuration class, and class methods like `client`, `config`, and `cancel`. The `client` method returns a memoized Temporal client connection built using `Client.build(config)`.
    *   **Recommendation:** Your test helper SHOULD use `ActiveJob::Temporal.configure` to set up test-specific configuration (e.g., test namespace, test target). You MUST be aware that the client is memoized (`@client ||= ...`), so you'll need to reset it in your test helper if you want to use a test-specific client instead of the production one.
    *   **Critical Detail:** The configuration defaults are: `target: "127.0.0.1:7233"`, `namespace: "default"`. For integration tests, you should override the namespace to "test" to isolate test workflows.

*   **File:** `lib/activejob/temporal/client.rb`
    *   **Summary:** This module provides the `Client.build(configuration)` method that creates a connection to Temporal using `Temporalio::Client.connect(target, namespace, **kwargs)`. It supports TLS configuration via environment variables or configuration object.
    *   **Recommendation:** Your `TemporalTestHelper.client` method SHOULD follow a similar pattern. You can either:
      1. Configure `ActiveJob::Temporal` with test settings and use `ActiveJob::Temporal.client`
      2. Or create a separate client directly: `Temporalio::Client.connect("localhost:7233", "test")`
    *   **Note:** The file includes a `begin/rescue LoadError` block to handle the case where the Temporal SDK is not present. Your test helper should assume the SDK IS present (since integration tests require it), but you MAY want to add a check to provide a helpful error message if the SDK is missing.

*   **File:** `spec/unit/client_spec.rb`
    *   **Summary:** This file contains unit tests for the client connection logic. It uses `stub_const("Temporalio::Client", class_double("Temporalio::Client"))` to mock the Temporal client and tests memoization, TLS options, and error handling.
    *   **Key Pattern:** The test resets memoized state with `described_class.instance_variable_set(:@client, nil)` and `described_class.instance_variable_set(:@config, nil)` in the `before` block.
    *   **Recommendation:** Your integration test setup SHOULD NOT mock the Temporal client (unlike unit tests). Instead, you MUST connect to a real Temporal test server. However, you MAY need to reset the memoized client if you're using `ActiveJob::Temporal.client` in tests, to ensure it picks up test configuration.

### Implementation Tips & Notes

*   **Tip:** The Temporal Ruby SDK (temporalio gem v1.0.0) does NOT appear to provide a built-in test server utility like the Go or Java SDKs. Based on my analysis of the vendor/bundle directory, I do not see any `Temporalio::Testing` module or similar. Therefore, you should implement the **manual setup approach** documented in the task description.

*   **Critical Decision:** Since the SDK doesn't provide a test server, your `spec/support/temporal_test_server.rb` file should:
    1. Define a `TemporalTestHelper` module
    2. Provide a `TemporalTestHelper.client` method that connects to `localhost:7233` with namespace `"test"`
    3. Include comments/documentation explaining how to manually start the test server before running integration tests

*   **Manual Test Server Setup:** Document these options in comments in the helper file:
    - **Option 1 (Recommended)**: Use Temporal CLI: `temporal server start-dev --namespace test`
    - **Option 2**: Use Docker: `docker run -p 7233:7233 -p 8233:8233 temporalio/auto-setup:latest`
    - The test suite will connect to `localhost:7233` by default

*   **Directory Structure:** The task requires creating `spec/integration/` directory. This directory does NOT exist yet (I confirmed from the file tree). You MUST create it when adding `temporal_connection_spec.rb`.

*   **Test Namespace:** Use "test" as the namespace (as specified in acceptance criteria). This isolates integration test workflows from any development or production workflows that might be running on the same Temporal server.

*   **Smoke Test Strategy:** The smoke test should verify basic connectivity by listing workflows. The Temporal Ruby SDK likely provides a method like:
    - `client.list_workflows` (check SDK docs for exact signature)
    - Or `client.workflow_service.list_workflows`
    - The exact method name may vary, so you'll need to check the temporalio gem documentation or source code

*   **RSpec Tags:** Consider tagging integration specs with `:integration` to allow running them separately. Example:
    ```ruby
    RSpec.describe "Temporal connection", :integration do
      # ...
    end
    ```
    This enables running `rspec --tag integration` or `rspec --tag ~integration` (exclude integration tests).

*   **Rake Task Addition:** The acceptance criteria mention `rake spec:integration`. You SHOULD add this task to the Rakefile along with `rake spec:unit`. Example:
    ```ruby
    namespace :spec do
      RSpec::Core::RakeTask.new(:unit) do |t|
        t.pattern = 'spec/unit/**/*_spec.rb'
      end

      RSpec::Core::RakeTask.new(:integration) do |t|
        t.pattern = 'spec/integration/**/*_spec.rb'
      end
    end
    ```

*   **Configuration Approach:** I recommend configuring ActiveJob::Temporal for tests rather than creating a separate client. Pattern:
    ```ruby
    module TemporalTestHelper
      def self.setup
        ActiveJob::Temporal.configure do |config|
          config.target = ENV.fetch('TEMPORAL_TEST_TARGET', 'localhost:7233')
          config.namespace = 'test'
        end
        # Reset memoized client to pick up new config
        ActiveJob::Temporal.instance_variable_set(:@client, nil)
      end

      def self.client
        ActiveJob::Temporal.client
      end
    end
    ```

*   **Lifecycle Hooks:** Since there's no automatic server start/stop, you can use `before(:suite)` to configure the test client, but you should NOT try to start/stop a server automatically (it must be running manually). Use the hook to verify connectivity and fail fast if the server isn't available.

*   **Error Handling:** If the Temporal test server is not running when tests start, the connection will fail. You SHOULD catch this and provide a helpful error message directing users to start the server manually.

*   **Workflow Listing:** For the smoke test, listing workflows should return an empty array initially (assuming a clean test namespace). The assertion would be something like: `expect(workflows.to_a).to be_empty` or similar.

### Project Conventions

*   **Frozen String Literals:** All Ruby files in this project start with `# frozen_string_literal: true`. Your helper and test files MUST include this.

*   **RSpec Style:** The project uses RSpec 3.x with `expect` syntax (not `should`). Your smoke test must follow this convention.

*   **Module Naming:** Use `TemporalTestHelper` as the module name (as specified in acceptance criteria).

### Potential Pitfalls

*   **Warning:** The `spec/integration/` directory does NOT exist yet. You must create it (or the file write will fail).

*   **Warning:** The current spec_helper does NOT auto-load support files. You MUST explicitly require the helper file, or tests won't have access to `TemporalTestHelper`.

*   **Warning:** Memoized client state can cause issues. If `ActiveJob::Temporal.client` is called before test configuration is set, it will memoize the production config. Reset it in your test setup: `ActiveJob::Temporal.instance_variable_set(:@client, nil)`.

*   **Warning:** Integration tests require a running Temporal server. The tests will FAIL if the server isn't running. Provide clear error messages and documentation about this prerequisite.

*   **Warning:** The Temporal SDK's list workflows method may have a specific signature (e.g., require query parameters). You'll need to check the SDK documentation or source code to use it correctly. It might be something like `client.list_workflows(namespace: "test")` or similar.

*   **Tip:** If you have trouble finding the exact SDK method for listing workflows, you can verify connection more simply by checking that the client object is created without error and has the expected namespace. A minimal smoke test could just verify the client connects successfully.

---

## 4. Success Criteria Checklist

Use this checklist to verify your implementation meets all requirements:

- [ ] `spec/support/temporal_test_server.rb` exists
- [ ] File includes `TemporalTestHelper` module definition
- [ ] Helper includes documentation on how to manually start test server (comments explaining `temporal server start-dev` or Docker)
- [ ] Helper provides `TemporalTestHelper.client` method
- [ ] Helper configures Temporal to use "test" namespace
- [ ] Helper configures target to `localhost:7233` (or ENV-configurable)
- [ ] `spec/spec_helper.rb` is modified to require the temporal_test_server helper
- [ ] `spec/integration/` directory is created
- [ ] `spec/integration/temporal_connection_spec.rb` exists
- [ ] Smoke test requires `spec_helper`
- [ ] Smoke test connects to test server via `TemporalTestHelper.client`
- [ ] Smoke test lists workflows (or verifies connection in another way)
- [ ] Smoke test asserts that workflow list is empty initially
- [ ] Smoke test is properly structured (describe/it blocks)
- [ ] Rakefile is updated with `spec:unit` and `spec:integration` tasks (if not already present)
- [ ] Running `rake spec` passes (or provides clear error if server not running)
- [ ] Running `rake spec:integration` specifically runs integration tests
- [ ] All files include `# frozen_string_literal: true`
- [ ] Code passes Rubocop (will be checked in I4.T10, but avoid obvious violations)

---

## 5. Recommended File Structure

```
spec/
├── spec_helper.rb (MODIFY - add require for temporal_test_server)
├── support/ (already exists)
│   └── temporal_test_server.rb (NEW - create this file)
├── integration/ (NEW - create this directory)
│   └── temporal_connection_spec.rb (NEW - create this file)
└── unit/ (already exists)
    └── ... (existing unit tests)
```

---

## 6. Suggested Implementation Order

1. **First:** Create `spec/support/temporal_test_server.rb` with `TemporalTestHelper` module
2. **Second:** Modify `spec/spec_helper.rb` to require the helper
3. **Third:** Create `spec/integration/` directory
4. **Fourth:** Create `spec/integration/temporal_connection_spec.rb` with smoke test
5. **Fifth:** Update `Rakefile` to add `spec:unit` and `spec:integration` tasks
6. **Finally:** Test manually by starting Temporal server and running `rake spec:integration`

This order minimizes the chance of errors and allows incremental testing.
