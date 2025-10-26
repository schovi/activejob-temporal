# Code Refinement Task

The previous code submission did not pass verification. You must fix the following issues and resubmit your work.

---

## Original Task Description

```json
{
  "task_id": "I2.T4",
  "iteration_id": "I2",
  "iteration_goal": "Implement the core Temporal workflow (AjWorkflow) and activity (AjRunnerActivity) that orchestrate and execute ActiveJob jobs. Generate sequence diagrams for execution flows.",
  "description": "Create a helper method in `lib/activejob/temporal/adapter.rb` (or a separate helper module) for building deterministic workflow IDs. Implement `build_workflow_id(job)` method that returns a string in format `\"ajwf:#{job.class.name}:#{job.job_id}\"`. This ensures idempotent enqueue (same job_id → same workflow_id → Temporal rejects duplicate via `:reject` conflict policy). Write unit tests in `spec/unit/adapter_spec.rb` (this spec will be expanded in I3) covering: workflow ID format, determinism (same job → same ID), uniqueness across job classes. This is a small helper but critical for deduplication.",
  "agent_type_hint": "BackendAgent",
  "inputs": "Section 3.7 (Interaction Flow - Workflow ID Generation), ActiveJob job structure",
  "target_files": [
    "lib/activejob/temporal/adapter.rb",
    "spec/unit/adapter_spec.rb"
  ],
  "input_files": [],
  "deliverables": "Working workflow ID builder, passing unit tests",
  "acceptance_criteria": "`build_workflow_id(job)` returns string in format `\"ajwf:<ClassName>:<job_id>\"`; Example: For `SendInvoiceJob` with job_id \"abc-123\", returns `\"ajwf:SendInvoiceJob:abc-123\"`; Calling `build_workflow_id` twice with same job returns same string (deterministic); Different job classes with same job_id return different workflow IDs (class name prevents collision); Unit tests verify format and determinism; `rake spec` passes for adapter_spec.rb; Code passes `rake rubocop`",
  "dependencies": [],
  "parallelizable": true,
  "done": false
}
```

---

## Issues Detected

* **Test Failures:** `bundle exec rake spec` currently fails in `spec/unit/client_spec.rb` (five examples) because `Temporalio::Client.connect` is now verified as taking two positional arguments (`target_host`, `namespace`). The implementation in `lib/activejob/temporal/client.rb` still passes a single kwargs hash (`Temporalio::Client.connect(**connection_options(configuration))`). When RSpec creates the verifying double, it raises `ArgumentError: Wrong number of arguments. Expected 2, got 1.` before the new adapter specs even run, so the suite does not satisfy the acceptance criterion that `rake spec` passes.

---

## Best Approach to Fix

Update `ActiveJob::Temporal::Client.build` to match the current Temporal Ruby SDK API: call `Temporalio::Client.connect(configuration.target, configuration.namespace, **client_options)` so the target host and namespace are passed positionally, and keep optional settings (currently TLS) in the keyword hash. Adjust `spec/unit/client_spec.rb` expectations to assert the two positional args plus any keywords (`tls`). After syncing implementation and spec, rerun `bundle exec rake spec` to confirm the full test suite passes, then revalidate `bundle exec rake rubocop`.
