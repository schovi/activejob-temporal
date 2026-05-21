# Video Walkthrough Script

This script is the recording plan for GitHub issue
[#32](https://github.com/schovi/activejob-temporal/issues/32). It is not the
finished walkthrough asset. The issue is complete only after a public video or
animated GIF is recorded, published, and embedded in the README.

Target length: about 5 minutes.

## Recording Setup

- Use the [Basic Rails App](../examples/basic_rails_app/) as the demo app.
- Use Ruby 4.0.3 for any local commands. Do not install Ruby 3 or use Ruby 3 as
  a fallback while preparing the recording.
- Start the stack from the example app:

  ```bash
  cd examples/basic_rails_app
  docker-compose up
  ```

- Wait until the logs show the Rails app, Temporal server, Temporal UI, search
  attribute registration, and Temporal worker are ready.
- Open:
  - Rails API: <http://localhost:3000>
  - Temporal UI: <http://localhost:8080>
- Keep a terminal visible for the curl commands and worker logs.
- Hide unrelated browser tabs, credentials, and personal shell history.

## Scene Plan

| Time | Screen | Talking Points |
| --- | --- | --- |
| 0:00 to 0:25 | Repository README | Introduce activejob-temporal as a Rails ActiveJob adapter that runs jobs through Temporal workflows. Point out durable execution, retries, and Temporal UI observability. |
| 0:25 to 0:55 | `examples/basic_rails_app/README.md` | Show that the example app is the quickstart path. Call out Rails, Temporal, Temporal UI, search attributes, seeded GlobalID records, and the worker. |
| 0:55 to 1:25 | Terminal running `docker-compose up` | Show the single command that starts the local stack. Pause on ready logs from the Rails app and Temporal worker. |
| 1:25 to 1:55 | Terminal | Enqueue a simple job with `curl -X POST http://localhost:3000/jobs/simple`. Point out the returned job ID and queue. |
| 1:55 to 2:30 | Temporal UI workflow list | Open Temporal UI and show the new ActiveJob workflow. Filter by class or job ID if needed. |
| 2:30 to 3:05 | Temporal UI workflow history | Open the workflow history and show the activity execution created by ActiveJob. Mention that this is the same job lifecycle Rails developers trigger with `perform_later`. |
| 3:05 to 3:40 | Terminal | Enqueue a retryable job with `curl -X POST "http://localhost:3000/jobs/retryable?should_fail=true"`. Keep the response visible long enough to capture the `attempt_key`. |
| 3:40 to 4:20 | Worker logs and Temporal UI history | Show the transient failures and final success. Point out that ActiveJob `retry_on` maps to Temporal retry policy behavior. |
| 4:20 to 4:45 | Temporal UI search attributes | Show `ajClass`, `ajQueue`, `ajJobId`, and related search attributes. Use the existing screenshot names as a guide for the views to capture. |
| 4:45 to 5:00 | Docs index or README links | Close by pointing to the Rails example, worker setup, troubleshooting, and retry policy docs. |

## Commands To Capture

```bash
cd examples/basic_rails_app
docker-compose up
```

```bash
curl -X POST http://localhost:3000/jobs/simple
```

```bash
curl -X POST "http://localhost:3000/jobs/retryable?should_fail=true"
```

Optional GlobalID segment if the recording is running under five minutes:

```bash
curl -X POST "http://localhost:3000/jobs/campaign_email?subscriber_id=1"
```

## Acceptance Checklist

The finished asset should show:

- The quickstart path from the Rails example.
- The stack starting with Rails, Temporal, Temporal UI, and a worker.
- A simple job being enqueued and appearing in Temporal UI.
- Workflow history for at least one job.
- Retry behavior for the retryable job.
- Search attributes in Temporal UI.
- A public video URL or checked-in animated GIF path.
- README embedding that sends users directly to the public walkthrough.

## Embedding Plan

After the video or GIF exists:

1. Add the public link or checked-in asset to the README quickstart or examples
   section.
2. Link the asset from the Basic Rails App README.
3. Update issue #32 with the published URL and verification notes.
4. Keep this script if it still matches the recording, or update it to reflect
   the final asset.
