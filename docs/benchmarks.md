# Performance Benchmarks

The repository includes a `benchmark-ips` suite for core adapter operations. The suite is synthetic and does not require a Temporal server. Enqueue benchmarking uses the real `WorkflowEnqueuer` with a fake Temporal client, so serialization, workflow ID generation, retry mapping, search attributes, and logging overhead still run locally.

Run the full suite:

```bash
bundle exec rake benchmark
```

For a faster smoke run:

```bash
BENCHMARK_TIME=1 BENCHMARK_WARMUP=1 bundle exec rake benchmark
```

Use the smoke run while iterating and the full run when recording release or optimization notes.

## Benchmarked Operations

| Operation | What it measures |
| --- | --- |
| `enqueue job` | `WorkflowEnqueuer#enqueue` with payload building, retry mapping, workflow ID generation, task queue resolution, search attributes, and structured enqueue logging. |
| `build payload` | `Payload.from_job` serialization and payload size enforcement. |
| `config access` | `ActiveJob::Temporal.config.target` reader throughput. |
| `workflow id generation` | `WorkflowIdBuilder#build` and workflow ID validation. |
| `retry policy calculation` | `RetryMapper.for` on a job with `retry_on` and `discard_on`. |

## Initial Baseline

Measured with Ruby 4.0.3 using:

```bash
BENCHMARK_TIME=1 BENCHMARK_WARMUP=1 bundle exec rake benchmark
```

| Operation | Throughput |
| --- | ---: |
| `config access` | 6.29M i/s |
| `workflow id generation` | 1.55M i/s |
| `build payload` | 203.96k i/s |
| `enqueue job` | 3.94k i/s |
| `retry policy calculation` | 1.36k i/s |

These numbers are hardware-specific. Use them as a local regression reference, not as universal production targets. Re-record the table when benchmark setup, Ruby version, or representative job shape changes.
