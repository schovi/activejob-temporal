# Recurring Jobs

Use Temporal Schedules when a job should run repeatedly on a cron expression. This is separate from ActiveJob's delayed execution API, which is still the right fit for one-off `set(wait:)` and `set(wait_until:)` jobs.

## Declare A Schedule

Declare the schedule on the job class:

```ruby
class DailyReportJob < ApplicationJob
  queue_as :reports

  temporal_schedule cron: "0 2 * * *", timezone: "America/New_York", overlap_policy: :skip

  def perform(account_id)
    DailyReport.generate_for(account_id)
  end
end
```

The `temporal_schedule` declaration is local metadata only. It does not call Temporal while Rails loads job classes.

## Register A Schedule

Register the declared schedule during deployment or from a Rails task:

```ruby
DailyReportJob.create_temporal_schedule(args: [account.id], id: "daily-report:#{account.id}")
```

You can also register an ad hoc schedule without a class declaration:

```ruby
DailyReportJob.create_temporal_schedule(
  id: "daily-report:#{account.id}",
  cron: "0 */6 * * *",
  timezone: "UTC",
  overlap_policy: :skip,
  args: [account.id],
  queue: :reports
)
```

If a schedule with the same ID already exists, registration returns the existing schedule handle. This keeps deployment registration idempotent.

## Options

| Option | Required | Description |
| --- | --- | --- |
| `cron` | Yes | Cron expression string, or an array of cron expressions. Temporal validates cron semantics. |
| `timezone` | No | IANA time zone name. Defaults to `UTC`. |
| `overlap_policy` | No | What Temporal should do when a prior run is still active. Defaults to `:skip`. |
| `id` | No | Temporal schedule ID. Defaults to `ajsch:<JobClass>`. Use explicit IDs for per-tenant or per-account schedules. |
| `args` | No | Array of job arguments passed to `perform`. Defaults to `[]`. |
| `queue` | No | ActiveJob queue name to route scheduled runs to. Defaults to the job class queue. |
| `paused` | No | Create the schedule paused. Defaults to `false`. |
| `trigger_immediately` | No | Trigger one run during creation. Defaults to `false`. |

Supported overlap policies:

- `:skip`
- `:buffer` or `:buffer_one`
- `:buffer_all`
- `:allow_all`
- `:cancel_other`
- `:terminate_other`

## Schedule Handles

Use the schedule handle for operations provided by the Temporal Ruby SDK:

```ruby
handle = DailyReportJob.temporal_schedule_handle(id: "daily-report:42")
handle.pause(note: "Paused during maintenance")
handle.unpause
handle.trigger
handle.delete
```

## Schedule And Execution Identity

The schedule `id` is the stable control-plane identifier. Use it to register, pause, resume, trigger, or delete the schedule. The same `id` is also kept in Temporal search attributes so all occurrences from one schedule can be grouped together.

Each fire starts a separate workflow execution. Temporal uses the configured workflow ID as a prefix and appends occurrence-specific entropy when it can. ActiveJob combines the occurrence workflow ID with the workflow run ID for `job_id`, `provider_job_id`, and the job idempotency key, so even two manual triggers in the same second get distinct execution identities.

## Worker Requirement

Temporal Schedules start normal `ActiveJob::Temporal::Workflows::AjWorkflow` executions. Run a worker for the schedule's task queue:

```bash
ACTIVEJOB_TEMPORAL_TASK_QUEUE=reports bundle exec temporal-worker
```

Scheduled workflow payloads are static. If each account, tenant, or report needs different arguments, create one schedule per argument set with a stable explicit `id`.
