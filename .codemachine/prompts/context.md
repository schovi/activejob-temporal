# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I5.T3",
  "iteration_id": "I5",
  "iteration_goal": "Complete comprehensive documentation (README, API docs, migration guide), create example Rails app, finalize gemspec, prepare CHANGELOG, and ensure gem is ready for v0.1.0 release.",
  "description": "Create docs/migration_guide.md with high-level guidance for migrating from traditional job queues (Sidekiq, Resque, Delayed Job) to activejob-temporal. The guide should include: (1) Why Migrate, (2) Prerequisites, (3) Migration Strategy (Dual-Write Approach, Gradual Migration, Testing), (4) Code Changes, (5) Worker Deployment, (6) Draining Old Queue, (7) Rollback Plan, (8) Common Gotchas (payload size limits, idempotency, heartbeating for cancellation), (9) Testing Checklist, (10) Resources. Aim for ~100-200 lines, practical and actionable.",
  "agent_type_hint": "DocumentationAgent",
  "inputs": "Migration best practices, Sidekiq/Resque architecture knowledge, Temporal migration patterns, gem features from I1-I4",
  "target_files": [
    "docs/migration_guide.md"
  ],
  "input_files": [
    "README.md"
  ],
  "deliverables": "Practical migration guide with clear steps and gotchas",
  "acceptance_criteria": "docs/migration_guide.md exists and is ~100-200 lines; All required sections are present; Guide provides actionable steps (not just theory); Common gotchas are clearly called out (payload size, idempotency, heartbeating); Markdown is properly formatted; Guide is linked from README",
  "dependencies": [
    "I5.T1"
  ],
  "parallelizable": true,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: key-objectives (from 01_Context_and_Drivers.md)

The gem's key objectives include:
- **Functional Objectives**: Provide a production-ready ActiveJob adapter backed by Temporal
- **Non-Functional Objectives**:
  - Reliability through durable execution and fault tolerance
  - Observability via Temporal UI and search attributes
  - Maintainability with clean architecture and comprehensive documentation
  - Minimal learning curve for developers familiar with ActiveJob

### Context: scope (from 01_Context_and_Drivers.md)

**What's included in v0.1:**
- Temporal workflows and activities for job execution
- ActiveJob adapter integration
- Retry and discard mapping from ActiveJob to Temporal
- Job cancellation API
- Search attributes for observability
- Worker bootstrap script

**Explicitly out of scope for v0.1:**
- Multi-activity workflows (job chains)
- Recurring jobs via Temporal Schedules API
- Rails generators
- Built-in metrics and alerting

### Context: nfr-reliability (from 01_Context_and_Drivers.md)

**Reliability Requirements:**
- Jobs must execute at-least-once with Temporal's durable execution guarantees
- Worker failures must not lose job state or progress
- Transient network/infrastructure failures must be retried automatically
- Job state must survive process restarts and deployments

### Context: nfr-observability (from 01_Context_and_Drivers.md)

**Observability Requirements:**
- Temporal UI integration for real-time job monitoring
- Search attributes for filtering and debugging (ajClass, ajQueue, ajJobId, ajTenantId, ajEnqueuedAt)
- Structured JSON logging for integration with observability stacks
- Workflow history for debugging and audit trails

### Context: nfr-security (from 01_Context_and_Drivers.md)

**Security Considerations:**
- **Payload Safety**: 250KB payload size limit to prevent DoS
- **Serialization Safety**: Use ActiveJob's serializer to prevent arbitrary code execution
- **Network Security**: TLS encryption for Temporal connections
- **Namespace Isolation**: Use separate namespaces for multi-tenant scenarios

### Context: architectural-style (from 02_Architecture_Overview.md)

**Adapter + Orchestration Pattern:**
- ActiveJob adapter layer translates `perform_later` calls to Temporal workflow starts
- Each job becomes a Temporal workflow containing a single activity
- Workflows handle scheduling (via Workflow.sleep), activities execute job logic
- Retry policies mapped from ActiveJob's `retry_on`/`discard_on` to Temporal RetryPolicy

### Context: tech-stack-no-external-services (from 02_Architecture_Overview.md)

**Services NOT Required (compared to traditional stacks):**
- No Redis for queue storage
- No PostgreSQL queue tables
- No separate job persistence layer
- Temporal handles all persistence, scheduling, and coordination

### Context: deployment-constraints (from 01_Context_and_Drivers.md)

**Deployment Requirements:**
- Worker processes must have access to Temporal cluster
- Workers poll task queues for jobs
- Multiple workers can run in parallel for horizontal scaling
- Graceful shutdown required to avoid interrupting in-flight jobs

### Context: known-risks-and-mitigation (from 06_Rationale_and_Future.md)

**Risk: Migration from Existing Queue**
- **Likelihood**: High (common use case)
- **Impact**: Medium (potential job loss during cutover)
- **Mitigation**:
  - Dual-write approach: temporarily write to both old and new queue
  - Drain old queue completely before removing old workers
  - Test rollback plan before production migration
  - Monitor both systems during transition period

### Context: evolution-v02 (from 06_Rationale_and_Future.md)

**Planned for v0.2:**
- Temporal Schedules API for recurring jobs
- Enhanced OpenTelemetry tracing
- Rate limiting and circuit breakers
- Dead letter queue for permanently failed jobs

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `README.md`
    *   **Summary:** This is the comprehensive user-facing documentation that covers all gem features. It already contains a "Migration from Sidekiq/Resque" section (lines 413-427) that provides a high-level overview but explicitly references that "a detailed migration guide with side-by-side comparisons and edge case handling will be available in `docs/migration_guide.md` (coming in v0.1)".
    *   **Recommendation:** You MUST read this section carefully. Your migration guide should expand on these steps with detailed explanations and practical examples. Do NOT duplicate the README content verbatim; instead, provide the deeper dive that's promised. Reference back to README sections where appropriate.

*   **File:** `docs/configuration_reference.md`
    *   **Summary:** This file documents all configuration options including `max_payload_size_kb` (250KB default), search attributes, and Temporal connection settings.
    *   **Recommendation:** You SHOULD reference this file when discussing configuration changes during migration. The 250KB payload limit is a critical "gotcha" that differs from traditional queues (especially Sidekiq which defaults to 1MB).

*   **File:** `docs/worker_setup.md`
    *   **Summary:** This file provides detailed instructions for running Temporal workers, including environment variables, process management, and graceful shutdown behavior.
    *   **Recommendation:** You SHOULD reference this file when discussing worker deployment strategy. Workers are a new operational component that doesn't exist in traditional queue setups.

*   **File:** `lib/activejob/temporal/adapter.rb`
    *   **Summary:** The core adapter that translates ActiveJob calls to Temporal workflow starts. Key features include:
      - `enqueue_after_transaction_commit?` returns true for transaction safety
      - Idempotent enqueuing via deterministic workflow IDs with FAIL conflict policy
      - Automatic payload validation and size checking
      - Search attributes attachment for observability
    *   **Recommendation:** When discussing code changes in the migration guide, highlight that the adapter change is as simple as `config.active_job.queue_adapter = :temporal`. However, you SHOULD explain the behavioral differences (transaction safety, idempotency) that developers should be aware of.

*   **File:** `lib/activejob/temporal/retry_mapper.rb`
    *   **Summary:** Translates ActiveJob's `retry_on`/`discard_on` DSL to Temporal RetryPolicy. Notable behaviors:
      - Multiple `retry_on` declarations are merged
      - `attempts: :unlimited` maps to `maximum_attempts: 0` in Temporal
      - Proc/Symbol wait values fall back to configured default (Temporal requires numeric intervals)
      - `discard_on` errors become `non_retryable_error_types`
    *   **Recommendation:** You SHOULD explain in the migration guide that retry behavior is automatically preserved when migrating from Sidekiq/Resque if jobs use ActiveJob's retry DSL. Note that custom Sidekiq retry logic (e.g., `sidekiq_options retry: 5`) will need to be converted to `retry_on` declarations.

*   **File:** `spec/fixtures/sample_jobs.rb`
    *   **Summary:** Contains example job classes demonstrating various patterns: SimpleJob, RetryableJob, DiscardableJob, LongRunningJob (with heartbeating for cancellation).
    *   **Recommendation:** You SHOULD use these as concrete examples in the migration guide. The LongRunningJob demonstrates the heartbeating pattern that's critical for proper cancellation support.

### Implementation Tips & Notes

*   **Tip:** The README already mentions "Drain the old queue" in its migration section (line 424). Your migration guide should provide specific instructions on HOW to do this safely (e.g., stop enqueueing new jobs to old queue, wait for queue depth to reach zero, verify no jobs remain).

*   **Tip:** The gem enforces a 250KB payload limit (configurable via `max_payload_size_kb`). This is a common migration gotcha because:
    - Sidekiq defaults to 1MB payload limit
    - Resque and DelayedJob often don't enforce strict limits
    - Developers may be passing large objects directly instead of GlobalID references
    - Include a specific section explaining how to identify large payloads and refactor to use database references

*   **Tip:** The adapter implements transaction-safe enqueuing via `enqueue_after_transaction_commit?`. This is a **behavior change** from some traditional adapters:
    - Sidekiq async adapter does NOT wait for transaction commit (known footgun)
    - This gem's behavior is safer but may reveal existing bugs in application code
    - Call this out explicitly as a potential "unexpected benefit" that may expose hidden issues

*   **Tip:** Workers are a new operational concern. Traditional queue setups often run workers as part of the web dyno/pod (e.g., `sidekiq` process in same container). Temporal workers MUST be separate processes polling task queues. Include guidance on:
    - Running workers as separate Kubernetes Deployments/StatefulSets
    - Configuring multiple workers per queue for redundancy
    - Using process managers (systemd, Foreman, etc.) for local development
    - Setting appropriate concurrency limits via `AJ_TEMPORAL_MAX_ACT`

*   **Note:** Cancellation is a feature that doesn't exist in most traditional queue systems. The migration guide should explain:
    - You can now cancel in-flight jobs via `ActiveJob::Temporal.cancel(JobClass, job_id)`
    - This requires jobs to call `Temporalio::Activity::Context.current.heartbeat` periodically
    - Without heartbeating, activities run to completion even after cancellation requested
    - This is an optional new capability, not a breaking change

*   **Note:** Search attributes provide unprecedented observability compared to traditional queues. Emphasize this as a major benefit:
    - Sidekiq Pro has searching but requires paid license
    - Resque and DelayedJob have limited/no search capabilities
    - Temporal search attributes are available in both self-hosted and Temporal Cloud
    - One-time setup required: registering attributes with `tctl` (documented in README line 98-105)

*   **Warning:** The dual-write migration strategy is critical to avoid job loss. Your guide should provide a detailed step-by-step approach:
    1. Deploy code with BOTH old and new adapters configured (feature flag or conditional logic)
    2. Start writing jobs to both queues
    3. Deploy Temporal workers and verify they're processing jobs
    4. Monitor both systems for 24-48 hours
    5. Stop writing to old queue (flip feature flag)
    6. Wait for old queue to drain completely
    7. Remove old queue workers and old adapter code
    8. Have rollback plan ready at each step

*   **Warning:** Job idempotency becomes even more critical with durable execution. While Temporal guarantees at-least-once execution, jobs MUST be idempotent:
    - Same job should produce same result if executed multiple times
    - Use database uniqueness constraints, idempotency keys, or check-then-act patterns
    - The gem provides `Thread.current[:aj_temporal_idempotency_key]` with workflow ID that jobs can use
    - This is not new (applies to all job systems) but Temporal makes it more visible

### Documentation Structure Guidance

Based on the task requirements, your migration guide should follow this structure:

1. **Why Migrate** (~10 lines)
   - Benefits of Temporal over traditional queues
   - Use cases that benefit most from migration

2. **Prerequisites** (~10 lines)
   - Required setup (Temporal cluster access)
   - Gem installation
   - Link to Quick Start in README

3. **Migration Strategy** (~30 lines)
   - Dual-Write Approach (detailed steps)
   - Gradual Migration timeline
   - Testing approach before full cutover

4. **Code Changes** (~30 lines)
   - Adapter configuration
   - Worker deployment setup
   - Retry DSL migration (Sidekiq → ActiveJob retry_on)
   - Example side-by-side code comparisons

5. **Worker Deployment** (~15 lines)
   - Worker process requirements
   - Scaling considerations
   - Reference to worker_setup.md

6. **Draining Old Queue** (~10 lines)
   - Specific steps to safely drain
   - Monitoring techniques
   - When it's safe to remove old workers

7. **Rollback Plan** (~10 lines)
   - How to revert if issues arise
   - What to monitor

8. **Common Gotchas** (~30 lines)
   - Payload size limits (250KB vs 1MB)
   - Transaction safety behavior changes
   - Idempotency requirements
   - Heartbeating for cancellation
   - Search attributes setup

9. **Testing Checklist** (~15 lines)
   - Pre-migration tests
   - During migration monitoring
   - Post-migration verification

10. **Resources** (~10 lines)
    - Links to README, configuration docs, worker setup
    - Temporal documentation
    - Community support channels

Total: ~180 lines (within target range)

### Writing Style Guidelines

- Use **practical, actionable language** (imperatives: "Deploy workers", "Monitor queue depth")
- Include **specific commands** where applicable (e.g., tctl commands, environment variables)
- Use **warning callouts** (> **Warning:**) for critical gotchas
- Use **code blocks** for configuration examples and side-by-side comparisons
- Reference existing documentation files with **links** (e.g., "[Worker Setup Guide](worker_setup.md)")
- Avoid abstract theory; focus on **concrete steps** developers can follow
