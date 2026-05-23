# Nexus Integration

Nexus is Temporal's cross-service operation model for durable calls from a workflow to an external service. In activejob-temporal it is an optional workflow-layer extension point, not part of ordinary ActiveJob execution.

## Current Boundary

Ordinary jobs still run through `ActiveJob::Temporal::Workflows::AjWorkflow` and `ActiveJob::Temporal::Activities::AjRunnerActivity`. The adapter, enqueuer, job payload schema, and Rails job API do not include Nexus fields.

Nexus client creation belongs in the workflow layer through `ActiveJob::Temporal::Workflows::WorkflowNexus#nexus_client_for`. Workflow code that explicitly needs a durable external operation can use that helper, while normal jobs continue to call activities.

The current Temporal Ruby SDK exposes `Temporalio::Workflow.create_nexus_client`, but the worker bridge in SDK 1.4.1 still creates workers with Nexus disabled. That means this gem defines the adoption boundary and workflow-side seam, but it does not register or run Nexus handlers yet.

## When To Use Nexus

Use a normal activity when:

- the work is part of running the ActiveJob itself
- the code runs inside the same Rails application or worker deployment
- retries, timeouts, heartbeats, middleware, and job audit events should follow the existing activity path
- the operation can be represented as a normal Ruby method call inside `perform`

Use Nexus when:

- a workflow must call a separate Temporal-backed service through a stable service contract
- the called service should own its worker, lifecycle, retries, and deployment cadence
- the call represents external orchestration rather than the job's local execution work
- the Rails team wants to adopt the integration explicitly for a specific workflow path

## Future Shape

Future Nexus support should add explicit workflow helpers or dedicated workflow classes that call `nexus_client_for`. It should not add implicit Nexus metadata to every job payload, change `ActiveJob::Temporal::Adapter`, or route `AjRunnerActivity` through Nexus.

When the Ruby SDK exposes worker-side Nexus handler registration, activejob-temporal can add optional worker configuration for those handlers beside the existing workflow and activity registration in `bin/temporal-worker`. Until then, Nexus remains an opt-in workflow integration boundary.
