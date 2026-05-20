# ADR 003: Adapter Helper Module Extraction

## Status

Accepted

Updated by TASK.021: workflow ID construction now lives in `WorkflowIdBuilder`.
`Adapter.build_workflow_id` remains as the public helper and delegates to that builder.
`WorkflowEnqueuer` accepts an injected builder and configured generators do not need
to change enqueue orchestration.

## Context

The `TemporalAdapter` class serves as the integration point between ActiveJob's queue adapter interface and Temporal's workflow client API. Two specific operations are central to its functionality:

1. **Workflow ID Construction**: Creates default or configured workflow IDs, enabling idempotent enqueuing.

2. **Task Queue Resolution**: Translates ActiveJob's queue names into Temporal task queue names, optionally applying configured prefixes.

The design must address: testability (edge cases for empty queue names, whitespace, prefix application), statelessness (pure functions returning strings), reusability (needed for job cancellation and workflow queries), and adapter lifecycle (tests shouldn't require full adapter instantiation with Temporal client dependencies).

## Decision

We extract workflow ID building and task queue resolution into a **separate `Adapter` helper module** with module-level functions using Ruby's `module_function` pattern.

### Implementation

The `ActiveJob::Temporal::Adapter` module provides two public utility functions.
Workflow ID construction delegates to `ActiveJob::Temporal::WorkflowIdBuilder`:

```ruby
# lib/activejob/temporal/adapter.rb (lines 11-53)
module ActiveJob::Temporal::Adapter
  module_function

  # Builds default or configured workflow ID
  def build_workflow_id(job)
    WorkflowIdBuilder.new(configured_workflow_id_generator).build(job)
  end

  # Resolves task queue name, applying configured prefix if present
  def resolve_task_queue(job)
    queue_name = job.queue_name.to_s.strip
    queue_name = "default" if queue_name.empty?
    prefix = ActiveJob::Temporal.config.task_queue_prefix
    return queue_name if prefix.nil? || prefix.to_s.strip.empty?
    "#{prefix}#{queue_name}"
  end
end
```

### Usage in TemporalAdapter

The adapter calls module methods to build workflow IDs and resolve task queues before starting workflows. The `module_function` directive makes methods callable without requiring instantiation.

## Consequences

### Positive

- **Independent Testability**: Tests can call helper methods directly without mocking Temporal clients or ActiveJob infrastructure.
- **Improved Reusability**: Other components (job cancellation services) can use utilities without coupling to the adapter.
- **Clear Separation of Concerns**: `TemporalAdapter` focuses on orchestration (Temporal client calls, error handling, logging), while `Adapter` module handles data transformation (building IDs, resolving names).
- **Stateless Design**: `module_function` makes it explicit these are pure functions with no side effects.
- **Namespace Organization**: Helper methods under `ActiveJob::Temporal::Adapter` clarify purpose without polluting top-level namespace.

### Negative

- **Indirection for Simple Operations**: The workflow ID building logic is simple string interpolation. Extracting it adds indirection that some developers might find unnecessary.

- **Module Naming Confusion**: The helper module is named `Adapter`, while the adapter class is `TemporalAdapter`, which could be confusing at first glance.

- **Discoverability**: Developers might search in `TemporalAdapter` first before finding the helper module.

- **Potential for Over-Use**: This decision shouldn't set a precedent that *all* helper logic must be in separate modules.

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

Create separate `WorkflowIdBuilder` and `TaskQueueResolver` classes. **Original Why Not Chosen:** Over-engineering (two classes for two simple functions), namespace proliferation (two new top-level classes vs. single module), unnecessary boilerplate. Module functions provide same benefits with less complexity.

`WorkflowIdBuilder` was later extracted once workflow ID behavior needed its own extension point. Task queue resolution remains in the adapter helper.

### Alternative 3: Include Helper Logic Inline

Implement logic directly at call site. **Why Not Chosen:** Duplication risk (logic needed in enqueuing, cancellation, querying), reduced readability (clutters `enqueue_with_payload` with string manipulation), testing complexity (edge cases require full enqueue path instead of isolated unit tests).

### Alternative 4: Configuration-Based ID Generation

Allow configurable custom ID generators. **Original Why Not Chosen:** YAGNI (no current requirement, deterministic `ajwf:ClassName:JobId` meets all use cases), adds configuration complexity and validation overhead, compatibility risk (might break logging, monitoring, cancellation assumptions).

`workflow_id_generator` was later added once multi-tenant and custom idempotency use cases became concrete. `WorkflowIdBuilder` now owns ID validation, while cancellation uses search attributes to discover the actual workflow ID before requesting cancellation.

## References

- [Ruby Module Functions Documentation](https://docs.ruby-lang.org/en/master/Module.html#method-i-module_function)
- [Temporal Workflow IDs Best Practices](https://docs.temporal.io/workflows#workflow-id)
- [ActiveJob Queue Adapter Interface](https://api.rubyonrails.org/classes/ActiveJob/QueueAdapters.html)
- [Single Responsibility Principle](https://en.wikipedia.org/wiki/Single-responsibility_principle)
