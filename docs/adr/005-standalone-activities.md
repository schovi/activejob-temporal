# ADR 005: Standalone Activities as a Per-Class Opt-In

## Status

Accepted

## Context

Single-step jobs can use Temporal activity retries and timeouts without creating a workflow execution. The standalone activity API is experimental and cannot provide workflow orchestration or recurring schedules.

## Decision

Add the inherited `temporal_standalone_activity` opt-in. Direct enqueues start `AjRunnerActivity` with the same default execution ID and retry policy as workflow jobs.

| Standalone support | Features |
| --- | --- |
| Works | `perform_later`, batch enqueue, `set(wait:)`, `retry_on`, `discard_on`, timeouts, priority, idempotency keys, search attributes, `cancel`, `Inspect.status` |
| Skipped | Dead letter queue and its attempt limit. The adapter logs one warning per job class per process. |
| Rejected | Rate limits, chains, dependencies, child workflows, custom workflow identity, signals, queries, updates, and pause |
| Workflow only | Recurring schedules, `cancel_all`, and `cancel_where` |

## Consequences

Single-step jobs use one Temporal execution. Workers use the activity ID and namespace for idempotency and payload encryption. Cancel and inspect look up the other execution type when Temporal reports the preferred one missing.

Workflow execution remains the default. Standalone jobs require compatible SDKs and server settings. The distinct execution types have separate duplicate checks.

## Alternatives Considered

### Make standalone activities the default

Existing job classes can rely on workflow features and workflow visibility. An explicit opt-in avoids a change to those jobs when users upgrade.
