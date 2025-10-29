# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I4.T8",
  "iteration_id": "I4",
  "iteration_goal": "Implement the Temporal worker bootstrap script, write comprehensive integration tests with a real Temporal test server, and validate end-to-end functionality (enqueue → workflow → activity → job execution).",
  "description": "Write integration test in `spec/integration/enqueue_spec.rb` (same file, additional test) that verifies Search Attributes are attached to workflows. Test flow: (1) Enqueue a job (e.g., `TestJob.perform_later(42)`). (2) Start worker. (3) Wait for workflow to complete. (4) Query Temporal for the workflow using test client. (5) Verify workflow has Search Attributes: `ajClass == \"TestJob\"`, `ajQueue == \"default\"`, `ajJobId == job.job_id`, `ajEnqueuedAt` is a timestamp, `ajTenantId` is nil (or present if job has tenant context). This test proves Search Attributes builder works and attributes are persisted in Temporal.",
  "agent_type_hint": "BackendAgent",
  "inputs": "RSpec integration test patterns, Temporal test server, search attributes builder from I1.T7, Temporal search API documentation",
  "target_files": [
    "spec/integration/enqueue_spec.rb"
  ],
  "input_files": [
    "spec/support/temporal_test_server.rb",
    "lib/activejob/temporal/search_attributes.rb",
    "lib/activejob/temporal/adapter.rb"
  ],
  "deliverables": "Passing integration test verifying Search Attributes",
  "acceptance_criteria": "Integration test enqueues job, starts worker; Test waits for workflow to complete; Test queries workflow details using test client (`client.get_workflow_handle(workflow_id).describe`); Test verifies Search Attributes presence and values: `ajClass` == job class name, `ajQueue` == job queue name (or \"default\"), `ajJobId` == job.job_id, `ajEnqueuedAt` is a timestamp (Time object or ISO8601 string), `ajTenantId` is nil (or present if applicable); `rake spec:integration` passes for search attributes test in enqueue_spec.rb; Test is isolated",
  "dependencies": [
    "I3.T1",
    "I1.T7",
    "I4.T2"
  ],
  "parallelizable": false,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: data-entities (from 03_System_Structure_and_Data.md)

```markdown
#### **Key Data Entities**

**1. Job Payload (Workflow Input)**

The serialized representation of an ActiveJob that is passed to `AjWorkflow.execute`.

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `job_class` | String | Fully-qualified class name | `"SendInvoiceJob"` |
| `job_id` | String (UUID) | ActiveJob's unique identifier | `"a1b2c3d4-..."` |
| `queue_name` | String | ActiveJob queue name | `"billing"` |
| `arguments` | Array<Any> | Serialized job arguments (JSON-compatible) | `[42, {"key": "value"}]` |
| `scheduled_at` | ISO8601 String (optional) | Scheduled execution timestamp | `"2025-10-25T12:00:00Z"` |
| `executions` | Integer | Number of times job has been attempted | `0` (on first enqueue) |
| `exception_executions` | Hash | Retry metadata (from ActiveJob) | `{}` |

**2. Workflow Metadata (Temporal Search Attributes)**

Attached to the workflow on start, enabling queries in Temporal UI.

| Attribute | Type | Purpose | Example |
|-----------|------|---------|---------|
| `ajClass` | Keyword | Job class name for filtering | `"SendInvoiceJob"` |
| `ajQueue` | Keyword | Task queue/job queue | `"billing"` |
| `ajJobId` | Keyword | ActiveJob job_id for correlation | `"a1b2c3d4-..."` |
| `ajEnqueuedAt` | Datetime | Enqueue timestamp | `2025-10-25T12:00:00Z` |
| `ajTenantId` | Keyword (optional) | Multi-tenancy support | `"tenant-123"` |

**3. Retry Policy (Activity Configuration)**

Derived from ActiveJob's `retry_on`/`discard_on` DSL and passed to `execute_activity`.

| Field | Type | Source | Example |
|-------|------|--------|---------|
| `initial_interval` | Duration | `retry_on wait:` or config default | `30.seconds` |
| `backoff_coefficient` | Float | Config default (2.0) | `2.0` |
| `maximum_attempts` | Integer | `retry_on attempts:` or config default | `5` |
| `non_retryable_error_types` | Array<String> | `discard_on` exception classes | `["PSP::FatalError"]` |

**4. Configuration (Gem Settings)**

Stored in `ActiveJob::Temporal.config` singleton.

| Setting | Type | Default | Purpose |
|---------|------|---------|---------|
| `target` | String | `"127.0.0.1:7233"` | Temporal server address |
| `namespace` | String | `"default"` | Temporal namespace |
| `task_queue_prefix` | String (optional) | `nil` | Prefix for task queue names |
| `default_activity_timeout` | Duration | `15.minutes` | Activity start_to_close_timeout |
| `default_retry_initial_interval` | Duration | `30.seconds` | Retry initial delay |
| `default_retry_backoff` | Float | `2.0` | Exponential backoff factor |
| `default_retry_max_attempts` | Integer | `1` | Max retry attempts if no `retry_on` |
| `logger` | Logger | `Rails.logger` | Logging destination |
| `enable_tracing` | Boolean | `true` | OpenTelemetry tracing toggle |
```

### Context: decision-search-attributes (from 06_Rationale_and_Future.md)

```markdown
#### **Decision 5: Search Attributes for Visibility**

**Choice:** Attach `ajClass`, `ajQueue`, `ajJobId`, `ajEnqueuedAt`, `ajTenantId` as Search Attributes on workflow start.

**Rationale:**

- **Operational Queries**: Operators can filter workflows by job class, queue, or tenant in Temporal UI
- **Debugging**: Easy to find specific jobs by ActiveJob job_id
- **Monitoring**: Track job enqueue times, detect stale jobs

**Trade-offs:**

| Benefit | Cost |
|---------|------|
| Rich filtering in Temporal UI | Search Attributes must be pre-registered in Temporal schema |
| Fast queries (indexed) | Limited to keyword/datetime types (no arbitrary JSON) |
| Multi-tenant support (ajTenantId) | Requires Temporal cluster with Elasticsearch (for advanced search) |

**Alternatives Considered:**

1. **No Search Attributes**: Rely only on workflow history
   - **Rejected**: Hard to find jobs without full workflow ID; poor operational experience
2. **Custom Metadata Store**: Store job metadata in separate database
   - **Rejected**: Adds complexity; duplicates Temporal's built-in visibility

**Configuration Requirement**: Temporal cluster must have these Search Attributes registered:

```bash
tctl admin cluster add-search-attributes \
  --name ajClass --type Keyword \
  --name ajQueue --type Keyword \
  --name ajJobId --type Keyword \
  --name ajEnqueuedAt --type Datetime \
  --name ajTenantId --type Keyword
```
```

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### ⚠️ **CRITICAL DISCOVERY: TEST ALREADY EXISTS**

**File:** `spec/integration/enqueue_spec.rb` (lines 39-81)

**Summary:** The integration test for Search Attributes verification **already exists** in the codebase. The test is named "attaches search attributes to workflows for filtering and debugging" and is fully implemented.

**Current State:**
- ✅ Test enqueues a job using `TestJob.perform_later(42)`
- ✅ Test starts a worker and waits for job completion
- ✅ Test queries workflow description using `client.workflow_handle(workflow_id).describe`
- ✅ Test verifies all required Search Attributes:
  - `ajClass` == "TestJob"
  - `ajQueue` == "default"
  - `ajJobId` == job.job_id
  - `ajEnqueuedAt` is a Time object within 10 seconds of now
  - `ajTenantId` is nil (since job argument is integer, not tenant object)

**Recommendation:** This task appears to be **ALREADY COMPLETE**. The test exists and follows all acceptance criteria from the task specification.

### Relevant Existing Code

#### **File:** `lib/activejob/temporal/search_attributes.rb` (lines 1-43)

**Summary:** This module builds Temporal Search Attributes from ActiveJob instances. It creates properly typed search attribute keys and values.

**Key Implementation Details:**
- Uses `Temporalio::SearchAttributes` and `Temporalio::SearchAttributes::Key` classes
- Defines attribute types: `KEYWORD` for strings, `TIME` for timestamps, `INTEGER` for tenant IDs
- Core attributes: `ajClass`, `ajQueue`, `ajJobId`, `ajEnqueuedAt`
- Optional `ajTenantId` extracted from first argument if it responds to `tenant_id`
- Sets `ajEnqueuedAt` to `Time.now` at enqueue time

**Note:** The implementation uses `IndexedValueType::INTEGER` for `ajTenantId`, but the architecture documents specify it should be a `Keyword` type. This may be a discrepancy to address.

#### **File:** `lib/activejob/temporal/adapter.rb` (lines 78-82)

**Summary:** The TemporalAdapter conditionally attaches search attributes when enqueueing workflows.

**Key Implementation Details:**
- Search attributes are only added if `config.enable_search_attributes` is true
- Uses `SearchAttributes.for(job)` to build the attributes
- Passes attributes to workflow start via `options[:search_attributes]`

**Recommendation:** The configuration flag `enable_search_attributes` is checked before adding search attributes. Ensure your test environment has this flag enabled (it defaults to `true` based on `lib/activejob/temporal.rb:45`).

#### **File:** `spec/support/temporal_test_server.rb` (lines 1-122)

**Summary:** This helper manages the Temporal test server connection for integration tests.

**Key Implementation Details:**
- Uses `TEST_NAMESPACE = "test"` for all integration tests
- Provides `TemporalTestHelper.client` for accessing Temporal client
- Automatically sets up and tears down test configuration in RSpec hooks
- Validates connection by listing workflows on suite startup

**Recommendation:** Your test MUST use `TemporalTestHelper.client` to get the properly configured test client, not `ActiveJob::Temporal.client` directly.

#### **File:** `spec/fixtures/sample_jobs.rb` (lines 74-84)

**Summary:** Defines `TestJob` class used in integration tests.

**Key Implementation Details:**
- `TestJob` stores its last executed argument in a class variable `@@last_argument`
- Queues to `:default` queue
- Simple `perform` method that just stores the argument

**Recommendation:** Use `TestJob` for your search attributes test as it's the standard test job for integration tests.

### Implementation Tips & Notes

#### **Tip 1: Test Already Exists - Verify It Passes**

The test you're asked to write already exists in `spec/integration/enqueue_spec.rb` starting at line 39. Your primary action should be to:

1. **Run the test** to verify it passes: `bundle exec rspec spec/integration/enqueue_spec.rb:39`
2. **If the test fails**, debug and fix the issues
3. **If the test passes**, mark the task as complete and update the task status

#### **Tip 2: Understanding Temporal Search Attributes API**

The Temporal Ruby SDK uses a typed key system for search attributes:

```ruby
# Create a typed key
key = Temporalio::SearchAttributes::Key.new(
  "ajClass",
  Temporalio::SearchAttributes::IndexedValueType::KEYWORD
)

# Access attribute value from workflow description
search_attrs = description.search_attributes
value = search_attrs[key]  # Returns the value for that typed key
```

**Types available:**
- `KEYWORD` - for string values (ajClass, ajQueue, ajJobId, ajTenantId)
- `TIME` - for timestamp values (ajEnqueuedAt)
- `INTEGER` - for numeric values (currently used for ajTenantId but may need to be Keyword per docs)

#### **Tip 3: Test Pattern for Integration Tests**

All integration tests in this project follow a consistent pattern:

```ruby
RSpec.describe "Feature description", :integration do
  let(:client) { TemporalTestHelper.client }

  around do |example|
    # Save original adapter
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal

    # Clear test state
    TestJob.last_argument = nil

    example.run
  ensure
    # Restore original adapter
    ActiveJob::Base.queue_adapter = original_adapter
    stop_worker(@worker_thread)
    TestJob.last_argument = nil
  end

  it "tests specific behavior" do
    # 1. Enqueue job
    job = TestJob.perform_later(42)
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

    # 2. Start worker
    @worker_thread = start_worker

    # 3. Wait for completion
    wait_for_result(42)

    # 4. Verify results
    expect(TestJob.last_argument).to eq(42)

    # 5. Query Temporal
    handle = client.workflow_handle(workflow_id)
    description = handle.describe

    # 6. Make assertions
    expect(description.status).to eq(Temporalio::Client::WorkflowExecutionStatus::COMPLETED)
  ensure
    stop_worker(@worker_thread)
  end
end
```

#### **Tip 4: Handling Search Attributes Type Mismatch**

The architecture documents specify `ajTenantId` should be a `Keyword` type, but the current implementation uses `INTEGER`. When writing or verifying tests:

- **For nil values**: Both types will return `nil` when queried
- **For present values**: Ensure the type matches what `SearchAttributes.for(job)` sets
- **Current code uses**: `IndexedValueType::INTEGER` (line 26 of search_attributes.rb)
- **Architecture specifies**: `Keyword` type

This discrepancy should be noted but doesn't block the test from passing.

#### **Warning: Test Server Must Be Running**

Integration tests require a live Temporal server. Before running tests:

```bash
# Option 1: Local dev server
temporal server start-dev --namespace test

# Option 2: Docker
docker run --rm -p 7233:7233 -p 8233:8233 temporalio/auto-setup:latest
```

If the server is not running, tests will fail with a `TemporalTestHelper::ServerNotAvailableError`.

#### **Note: Search Attributes Must Be Pre-registered**

For search attributes to work in a real Temporal cluster, they must be pre-registered:

```bash
tctl admin cluster add-search-attributes \
  --name ajClass --type Keyword \
  --name ajQueue --type Keyword \
  --name ajJobId --type Keyword \
  --name ajEnqueuedAt --type Datetime \
  --name ajTenantId --type Keyword
```

However, the test dev server (`temporal server start-dev`) automatically registers common search attribute types, so this should not block your tests.

### Task Completion Strategy

Given that the test already exists, your strategy should be:

1. **Verify the existing test** in `spec/integration/enqueue_spec.rb:39-81`
2. **Run the test** to ensure it passes:
   ```bash
   bundle exec rspec spec/integration/enqueue_spec.rb -e "attaches search attributes"
   ```
3. **If the test passes**: Mark task I4.T8 as complete and proceed to the next task
4. **If the test fails**:
   - Debug the failure
   - Fix any issues in the implementation or test
   - Ensure all acceptance criteria are met
5. **Document any findings** about the type mismatch (INTEGER vs Keyword for ajTenantId)

### Acceptance Criteria Verification Checklist

✅ Integration test enqueues job → **CONFIRMED** (line 40)
✅ Test starts worker → **CONFIRMED** (line 43)
✅ Test waits for workflow to complete → **CONFIRMED** (line 45)
✅ Test queries workflow details using `client.workflow_handle(workflow_id).describe` → **CONFIRMED** (lines 51-52)
✅ Test verifies Search Attributes presence and values:
  - `ajClass` == job class name → **CONFIRMED** (line 67)
  - `ajQueue` == job queue name → **CONFIRMED** (line 68)
  - `ajJobId` == job.job_id → **CONFIRMED** (line 69)
  - `ajEnqueuedAt` is a timestamp → **CONFIRMED** (lines 72-74)
  - `ajTenantId` is nil → **CONFIRMED** (lines 77-78)
✅ Test is isolated → **CONFIRMED** (around block cleans up state)

**All acceptance criteria are met by the existing test.**
