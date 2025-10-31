# ADR 003: Adapter Helper Module Extraction

## Status

Accepted

## Context

The `TemporalAdapter` class serves as the integration point between ActiveJob's queue adapter interface and Temporal's workflow client API. It implements the required methods `enqueue(job)` and `enqueue_at(job, timestamp)` that Rails calls when jobs are enqueued.

Two specific operations are central to the adapter's functionality:

1. **Workflow ID Construction**: Every Temporal workflow requires a unique identifier. The adapter creates deterministic workflow IDs from ActiveJob's job class and job ID, enabling idempotent enqueuing (duplicate enqueue calls with the same job_id are rejected by Temporal).

2. **Task Queue Resolution**: Temporal workers listen to specific task queues. The adapter must translate ActiveJob's queue names (e.g., "mailers", "default") into Temporal task queue names, optionally applying configured prefixes for multi-tenant deployments.

### Initial Design Question

When implementing these operations, we faced a choice about code organization:

**Should these methods be:**
- Private instance methods on the `TemporalAdapter` class?
- Public instance methods callable from outside the adapter?
- Stateless utility functions in a separate module?
- Methods on dedicated utility classes (`WorkflowIdBuilder`, `TaskQueueResolver`)?

### Key Considerations

1. **Testability**: The workflow ID format and task queue resolution logic have edge cases that require thorough unit testing:
   - Empty queue names should default to "default"
   - Queue name whitespace should be stripped
   - Optional prefixes should be applied correctly
   - Workflow IDs must be deterministic and unique

2. **Statelessness**: Both operations are pure functions—they take a job and configuration as input and return a string. They don't maintain state or depend on instance variables.

3. **Reusability**: Other parts of the system might need to construct workflow IDs or resolve task queues (e.g., job cancellation, workflow queries, monitoring tools).

4. **Adapter Lifecycle**: The `TemporalAdapter` is instantiated by Rails' ActiveJob framework. Tests that need to call these utility methods shouldn't require instantiating a full adapter with its Temporal client dependencies.

5. **Code Clarity**: The `enqueue` and `enqueue_at` methods already orchestrate multiple operations (payload building, client interaction, error handling). Extracting helper logic reduces complexity in the main methods.

### Problem Statement

How should we organize workflow ID building and task queue resolution to maximize testability, reusability, and maintainability without over-engineering the solution?

## Decision

We extract workflow ID building and task queue resolution into a **separate `Adapter` helper module** with module-level functions using Ruby's `module_function` pattern.

### Implementation

The `ActiveJob::Temporal::Adapter` module provides two public utility functions:

```ruby
# lib/activejob/temporal/adapter.rb (lines 11-53)

module ActiveJob
  module Temporal
    # Helper methods for the TemporalAdapter.
    #
    # This module provides utility functions for building workflow IDs and resolving
    # task queue names. Used internally by the adapter.
    module Adapter
      module_function

      # Builds deterministic workflow ID used for Temporal workflows.
      #
      # Creates a unique, reproducible workflow ID from the job class and job ID.
      # This enables idempotent enqueuing (duplicate enqueue calls with same job_id
      # will be rejected by Temporal with FAIL conflict policy).
      #
      # @param job [ActiveJob::Base] ActiveJob instance being enqueued
      # @return [String] Workflow ID in format "ajwf:<ClassName>:<job_id>"
      # @example
      #   job = MyJob.new
      #   job.job_id # => "abc-123"
      #   build_workflow_id(job) # => "ajwf:MyJob:abc-123"
      def build_workflow_id(job)
        "ajwf:#{job.class.name}:#{job.job_id}"
      end

      # Resolves the Temporal task queue name for a given job.
      #
      # Extracts the queue name from the job and applies the configured task_queue_prefix
      # if present. Defaults to "default" if queue_name is blank.
      #
      # @param job [ActiveJob::Base] ActiveJob instance being enqueued
      # @return [String] Task queue name, optionally prefixed
      # @example Without prefix
      #   job.queue_name # => "mailers"
      #   resolve_task_queue(job) # => "mailers"
      # @example With prefix
      #   ActiveJob::Temporal.config.task_queue_prefix = "myapp-"
      #   job.queue_name # => "mailers"
      #   resolve_task_queue(job) # => "myapp-mailers"
      def resolve_task_queue(job)
        queue_name = job.queue_name.to_s.strip
        queue_name = "default" if queue_name.empty?

        prefix = ActiveJob::Temporal.config.task_queue_prefix
        return queue_name if prefix.nil? || prefix.to_s.strip.empty?

        "#{prefix}#{queue_name}"
      end
    end
  end
end
```

### Usage in TemporalAdapter

The `TemporalAdapter` class calls these helper functions when enqueuing jobs:

```ruby
# lib/activejob/temporal/adapter.rb (lines 141-159)

def enqueue_with_payload(job, payload)
  workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)
  task_queue = ActiveJob::Temporal::Adapter.resolve_task_queue(job)
  client = ActiveJob::Temporal.client

  options = {
    id: workflow_id,
    task_queue: task_queue,
    id_conflict_policy: Temporalio::WorkflowIDConflictPolicy::FAIL
  }

  # Add search attributes if configured
  if ActiveJob::Temporal.config.respond_to?(:enable_search_attributes) && ActiveJob::Temporal.config.enable_search_attributes
    search_attributes = ActiveJob::Temporal::SearchAttributes.for(job)
    options[:search_attributes] = search_attributes
  end

  start_workflow(client, payload, options, job)
end
```

### Module-Level Functions Pattern

The `module_function` directive makes methods callable both as instance methods and module methods:

```ruby
module Adapter
  module_function

  def build_workflow_id(job)
    # ...
  end
end

# Can be called as module method (preferred):
ActiveJob::Temporal::Adapter.build_workflow_id(job)

# Also works as instance method (not typically used):
include ActiveJob::Temporal::Adapter
build_workflow_id(job)
```

This pattern provides namespace organization without requiring instantiation.

## Consequences

### Positive

- **Independent Testability**: Tests can call helper methods directly without mocking Temporal clients or ActiveJob infrastructure:
  ```ruby
  RSpec.describe ActiveJob::Temporal::Adapter do
    describe ".build_workflow_id" do
      it "creates deterministic IDs" do
        job = double(class: MyJob, job_id: "abc-123")
        expect(described_class.build_workflow_id(job)).to eq("ajwf:MyJob:abc-123")
      end
    end
  end
  ```

- **Improved Reusability**: Other components can use these utilities without coupling to the adapter:
  ```ruby
  # In a job cancellation service:
  workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)
  client.cancel_workflow(workflow_id)
  ```

- **Clear Separation of Concerns**: The `TemporalAdapter` class focuses on orchestration (calling Temporal client, handling errors, logging), while the `Adapter` module handles data transformation (building IDs, resolving names).

- **Stateless Design**: Using `module_function` makes it explicit that these are pure functions with no side effects or instance state.

- **Namespace Organization**: The helper methods live under `ActiveJob::Temporal::Adapter`, making their purpose clear (adapter utilities) without polluting the top-level namespace.

- **Easy Mocking in Tests**: Tests that need to verify adapter behavior can stub module methods:
  ```ruby
  allow(ActiveJob::Temporal::Adapter).to receive(:build_workflow_id).and_return("test-id")
  ```

### Negative

- **Indirection for Simple Operations**: The workflow ID building logic is a simple string interpolation (`"ajwf:#{class}:#{id}"`). Extracting it into a separate module adds a level of indirection that some developers might find unnecessary.

- **Module Naming Confusion**: The helper module is named `Adapter`, while the adapter class is `TemporalAdapter`. This could be confusing at first glance:
  - `ActiveJob::Temporal::Adapter` = helper module
  - `ActiveJob::QueueAdapters::TemporalAdapter` = adapter class

  However, the full qualified names are distinct, and usage context makes the distinction clear.

- **Discoverability**: Developers unfamiliar with the codebase might not immediately know where to find workflow ID building logic. They might search in `TemporalAdapter` first, then need to trace to the helper module.

- **Potential for Over-Use**: If every simple operation were extracted into a module, the codebase could become fragmented. This decision should not set a precedent that *all* helper logic must be in separate modules.

### Neutral

- **Future Extension Points**: If workflow ID or task queue logic becomes more complex (e.g., supporting multiple ID formats, custom queue resolvers), the module provides a natural extension point without changing the adapter's API.

## Alternatives Considered

### Alternative 1: Private Instance Methods on TemporalAdapter

Keep the helpers as private methods within the `TemporalAdapter` class:

```ruby
class TemporalAdapter
  def enqueue(job)
    workflow_id = build_workflow_id(job)
    task_queue = resolve_task_queue(job)
    # ...
  end

  private

  def build_workflow_id(job)
    "ajwf:#{job.class.name}:#{job.job_id}"
  end

  def resolve_task_queue(job)
    # ...
  end
end
```

**Why Not Chosen:**

- **Testing Friction**: Testing private methods requires either:
  - Making them public (breaks encapsulation)
  - Using `send(:build_workflow_id, job)` (bypasses access control, brittle)
  - Testing only through public methods (requires more complex test setup)

- **Coupling**: The adapter class becomes responsible for both orchestration and data transformation, violating single responsibility principle.

- **Reusability**: Other components can't easily call these helpers without instantiating the adapter.

### Alternative 2: Dedicated Utility Classes

Create separate classes for each concern:

```ruby
class WorkflowIdBuilder
  def self.build(job)
    "ajwf:#{job.class.name}:#{job.job_id}"
  end
end

class TaskQueueResolver
  def self.resolve(job)
    # ...
  end
end

# Usage:
workflow_id = WorkflowIdBuilder.build(job)
task_queue = TaskQueueResolver.resolve(job)
```

**Why Not Chosen:**

- **Over-Engineering**: Creating two classes for two simple functions adds unnecessary complexity. Each class would have a single method, providing no real organizational benefit over module functions.

- **Namespace Proliferation**: Introduces two new top-level classes instead of organizing related utilities under a single module.

- **Boilerplate**: Requires class definitions, `self` keywords, and separate files (or a bloated single file).

The module function approach provides the same benefits (testability, reusability) with less boilerplate.

### Alternative 3: Include Helper Logic Inline

Implement the logic directly inline at the call site:

```ruby
def enqueue_with_payload(job, payload)
  workflow_id = "ajwf:#{job.class.name}:#{job.job_id}"

  queue_name = job.queue_name.to_s.strip
  queue_name = "default" if queue_name.empty?
  prefix = ActiveJob::Temporal.config.task_queue_prefix
  task_queue = prefix && !prefix.to_s.strip.empty? ? "#{prefix}#{queue_name}" : queue_name

  # ...
end
```

**Why Not Chosen:**

- **Duplication Risk**: If multiple places need to build workflow IDs (enqueuing, cancellation, querying), the logic would be duplicated.

- **Readability**: The `enqueue_with_payload` method would become cluttered with string manipulation logic, obscuring the main workflow of "build ID → build queue → start workflow".

- **Testing Complexity**: Edge cases (empty queue names, whitespace, nil prefixes) would need to be tested through the full enqueue path rather than isolated unit tests.

### Alternative 4: Configuration-Based ID Generation

Allow users to configure custom ID generators via configuration:

```ruby
ActiveJob::Temporal.configure do |c|
  c.workflow_id_generator = ->(job) { "custom:#{job.job_id}" }
end
```

**Why Not Chosen:**

- **YAGNI (You Aren't Gonna Need It)**: There's no current requirement for custom workflow ID formats. The deterministic `ajwf:ClassName:JobId` format meets all known use cases.

- **Complexity**: Adds configuration overhead and requires validation (what if the generator returns nil? duplicates?).

- **Compatibility Risk**: Custom ID formats might break assumptions in other parts of the system (logging, monitoring, cancellation).

If custom ID generation becomes necessary in the future, the module provides a centralized location to add this feature without changing the adapter's interface.

## References

- [Ruby Module Functions Documentation](https://ruby-doc.org/core-3.0.0/Module.html#method-i-module_function)
- [Temporal Workflow IDs Best Practices](https://docs.temporal.io/workflows#workflow-id)
- [ActiveJob Queue Adapter Interface](https://api.rubyonrails.org/classes/ActiveJob/QueueAdapters.html)
- [Single Responsibility Principle](https://en.wikipedia.org/wiki/Single-responsibility_principle)
