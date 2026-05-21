# Systemd Worker Deployment

These files show one way to run `activejob-temporal` workers on a VM or bare-metal host with systemd.

## Files

| File | Purpose |
| --- | --- |
| `temporal-worker.service` | Single worker service polling one task queue. |
| `temporal-worker@.service` | Template service for running one worker per task queue. |
| `temporal-worker.logrotate` | Log rotation for file-based worker logs. |

## Install

Copy the service file and log rotation config into place:

```bash
sudo install -D -m 0644 examples/systemd/temporal-worker.service /etc/systemd/system/temporal-worker.service
sudo install -D -m 0644 examples/systemd/temporal-worker.logrotate /etc/logrotate.d/activejob-temporal-worker
sudo install -d -m 0755 /etc/activejob-temporal
```

Set deployment-specific values in `/etc/activejob-temporal/temporal-worker.env`:

```bash
RAILS_ENV=production
ACTIVEJOB_TEMPORAL_TARGET=temporal.example.com:7233
ACTIVEJOB_TEMPORAL_NAMESPACE=production
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=100
ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=5
```

Update these values in the service file before enabling it:

| Setting | Example | Notes |
| --- | --- | --- |
| `User` and `Group` | `deploy` | Must be able to read the app and run Bundler. |
| `WorkingDirectory` | `/var/www/myapp/current` | Must point at the Rails app root. |
| `ExecStart` | `/usr/bin/env bundle exec temporal-worker` | Assumes `bundle` resolves to a Ruby 4.0+ environment. |
| `ExecReload` | `/bin/kill -HUP $MAINPID` | Triggers worker TLS client reload without restarting the process. |

The service files load `temporal-worker.env` before setting task-queue-specific defaults. Keep shared connection settings in the env file, and set `ACTIVEJOB_TEMPORAL_TASK_QUEUE` in the service unit or template instance.

Reload systemd and start the worker:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now temporal-worker
sudo systemctl status temporal-worker
```

Restart the worker after deploys:

```bash
sudo systemctl restart temporal-worker
```

Reload TLS certificates without restarting the worker:

```bash
sudo systemctl reload temporal-worker
```

View logs:

```bash
sudo journalctl -u temporal-worker -f
sudo tail -f /var/log/activejob-temporal/worker.log
```

## Multiple Queues

Use the template unit when each queue should run as a separate systemd service:

```bash
sudo install -D -m 0644 examples/systemd/temporal-worker@.service /etc/systemd/system/temporal-worker@.service
sudo systemctl daemon-reload
sudo systemctl enable --now temporal-worker@default
sudo systemctl enable --now temporal-worker@billing
sudo systemctl enable --now temporal-worker@mailers
```

The `%i` instance name becomes `ACTIVEJOB_TEMPORAL_TASK_QUEUE`, so `temporal-worker@billing` polls the `billing` task queue.

## SELinux

On SELinux-enabled hosts, make sure the service user can read the application directory, execute the Ruby and Bundler binaries, and write to `/var/log/activejob-temporal`. If logs fail to open, check audit logs before relaxing systemd permissions.
