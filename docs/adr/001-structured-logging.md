# ADR 001: Structured JSON Logging

## Status

Accepted

## Context

Production observability is a critical requirement for any background job processing system. When jobs fail, retry, or exhibit unexpected behavior, operators need to quickly diagnose issues across distributed systems. The ActiveJob::Temporal gem bridges Rails applications with Temporal workflows, creating a complex execution environment spanning multiple processes and potentially multiple hosts.

Traditional plain-text logging presents several challenges in this context:

1. **Parsing Difficulty**: Plain text logs like `"Enqueued SendInvoiceJob with ID abc123 to queue invoices"` require complex regular expressions to extract structured data like job IDs, queue names, and timestamps.

2. **Inconsistent Format**: Without enforcement, different code paths may log similar events in different formats, making correlation difficult. For example, one developer might write `"Job abc123 enqueued"` while another writes `"Enqueued job: abc123"`.

3. **Limited Tooling Integration**: Modern log aggregation tools (Elasticsearch, Splunk, Datadog, CloudWatch Insights) are optimized for structured JSON data with well-defined fields. Plain text requires custom parsing pipelines.

4. **Missing Correlation IDs**: Temporal workflows span multiple activities and retries. Without consistent workflow_id and run_id fields in every log entry, tracing a single job's lifecycle becomes manually intensive.

5. **Production Requirements**: The gem must support both development environments (where human-readable logs are preferred) and production systems (where machine-parseable JSON is essential for observability platforms).

The logging strategy needed to balance human readability during development with production-grade observability requirements while maintaining backward compatibility with Rails' standard logging infrastructure.

## Decision

We implement a **structured JSON logging system** using an event-based semantic model through the `ActiveJob::Temporal::Logger` module.

### Core Design Principles

1. **Event-Centric Model**: All log entries include an `event` field describing what happened (e.g., `"job.enqueued"`, `"activity.failed"`), making it easy to filter and aggregate logs by event type.

2. **Mandatory Structured Attributes**: Every log entry includes a consistent base structure:
   - `event`: Event name (String or Symbol)
   - `timestamp`: ISO8601 UTC timestamp
   - Custom attributes (Hash) for event-specific data

3. **Type Safety**: The logger validates that event names are Strings or Symbols, and attributes are Hashes, preventing accidental logging of arbitrary objects.

4. **SemanticLogger Integration**: The implementation detects SemanticLogger availability and delegates to it when present, otherwise falls back to standard Ruby Logger with JSON serialization.

### Implementation

The `ActiveJob::Temporal::Logger` module provides three public methods corresponding to standard log levels:

```ruby
# lib/activejob/temporal/logger.rb (lines 46-70)

# Logs an event at INFO level.
def info(event_name, attributes = {})
  log(:info, event_name, attributes)
end

# Logs an event at WARN level.
def warn(event_name, attributes = {})
  log(:warn, event_name, attributes)
end

# Logs an event at ERROR level.
def error(event_name, attributes = {})
  log(:error, event_name, attributes)
end
```

The internal `log` method builds a consistent payload structure:

```ruby
# lib/activejob/temporal/logger.rb (lines 74-95)

def log(level, event_name, attributes)
  validate_event!(event_name)
  attributes = normalize_attributes(attributes)

  payload = build_payload(event_name, attributes)
  configured_logger = ActiveJob::Temporal.config.logger
  return unless configured_logger.respond_to?(level)

  if semantic_logger_available?
    configured_logger.public_send(level, payload)
  else
    configured_logger.public_send(level, JSON.generate(payload))
  end
end

def build_payload(event_name, attributes)
  { event: event_name, timestamp: current_timestamp }.merge(attributes)
end

def current_timestamp
  Time.now.utc.iso8601
end
```

### Usage Example

Throughout the codebase, logging calls follow a consistent pattern:

```ruby
# Enqueuing a workflow
Logger.info("workflow.enqueued",
  workflow_id: "ajwf:SendInvoiceJob:abc123",
  run_id: "run-456",
  job_class: "SendInvoiceJob",
  job_id: "abc123",
  queue: "invoices"
)
```

This produces the following JSON output:

```json
{
  "event": "workflow.enqueued",
  "timestamp": "2025-10-31T14:32:18Z",
  "workflow_id": "ajwf:SendInvoiceJob:abc123",
  "run_id": "run-456",
  "job_class": "SendInvoiceJob",
  "job_id": "abc123",
  "queue": "invoices"
}
```

### Standard Events Catalog

The gem defines a standard set of events documented in the operational architecture:

| Event | Level | Key Attributes |
|-------|-------|----------------|
| `workflow.enqueued` | info | `workflow_id`, `run_id`, `job_class`, `queue`, `scheduled_at` |
| `activity.started` | info | `workflow_id`, `activity_id`, `attempt` |
| `activity.completed` | info | `workflow_id`, `duration_ms` |
| `activity.failed` | error | `workflow_id`, `exception_class`, `exception_message`, `backtrace` |
| `activity.retry` | warn | `workflow_id`, `attempt`, `next_retry_interval` |
| `cancellation.requested` | warn | `workflow_id`, `reason` |
| `payload.size_warning` | warn | `job_class`, `payload_size_kb`, `limit_kb` |
| `serialization.error` | error | `job_class`, `exception_class`, `exception_message` |

## Consequences

### Positive

- **Production-Ready Observability**: JSON logs integrate seamlessly with modern log aggregation platforms without custom parsing pipelines.

- **Consistent Correlation**: Every log entry for a workflow includes the same `workflow_id` and `run_id`, enabling distributed tracing across activities, retries, and failures.

- **Query Efficiency**: Operators can write precise queries like `event:"activity.failed" AND job_class:"SendInvoiceJob"` instead of grep-style text searches.

- **Type Safety**: Validation prevents accidental logging of non-serializable objects or malformed events.

- **Backward Compatibility**: The fallback to Rails.logger with JSON serialization ensures the gem works in any Rails environment without requiring additional dependencies.

- **Development Ergonomics**: While JSON is less human-readable than plain text, tools like `jq` make it easy to pretty-print and filter logs during development:
  ```bash
  tail -f log/development.log | jq 'select(.event == "activity.failed")'
  ```

### Negative

- **Human Readability Trade-Off**: Raw JSON logs are harder to read than plain text when directly viewing log files without tooling. Developers need to use `jq` or similar tools for comfortable log browsing.

- **Payload Size**: JSON formatting adds overhead compared to plain text (field names repeated in every entry). For high-throughput systems, this increases log storage costs slightly (~20-30% larger than equivalent plain text).

- **Requires JSON Parsing**: Downstream consumers must parse JSON, which adds minimal CPU overhead compared to text splitting but does require JSON support in log viewers.

- **SemanticLogger Assumption**: While the code gracefully falls back to standard Logger, optimal integration assumes SemanticLogger is available. Projects not using SemanticLogger get serialized JSON strings rather than structured Hashes in their log streams.

- **Event Name Discipline**: The effectiveness of event-based logging depends on developers following consistent naming conventions. Without enforcement, event names can proliferate (e.g., `"job_enqueued"` vs `"job.enqueued"` vs `"enqueue_job"`).

## Alternatives Considered

### Alternative 1: Plain Text Logging with Tagged Logging

Rails' built-in `ActiveSupport::TaggedLogging` could provide some structure:

```ruby
Rails.logger.tagged("workflow_id:#{workflow_id}", "job_class:#{job_class}") do
  Rails.logger.info "Job enqueued to #{queue}"
end
```

**Why Not Chosen:**

- Tags are embedded in bracketed prefixes (`[workflow_id:abc123][job_class:MyJob] Job enqueued to invoices`), which still requires regex parsing to extract.
- No enforcement of consistent tag names or values.
- Limited integration with modern observability platforms that expect JSON fields.
- Tagged logging is designed for request-scoped context, not event-based telemetry.

### Alternative 2: Lograge-Style Minimal JSON

Use a minimal JSON format with only essential fields:

```ruby
Rails.logger.info({ wf: workflow_id, jc: job_class, q: queue }.to_json)
```

**Why Not Chosen:**

- Abbreviated field names (`wf`, `jc`) harm readability and require documentation.
- No standardization of event types—every log entry becomes a unique snowflake.
- Missing semantic information about *what happened* (event type).
- Doesn't provide a clear API for developers; encourages ad-hoc Hash construction.

### Alternative 3: Pluggable Logger Adapter Pattern

Create an adapter pattern allowing users to plug in different logging backends (JSON, plain text, custom):

```ruby
ActiveJob::Temporal.configure do |c|
  c.logger_adapter = PlainTextLoggerAdapter.new
end
```

**Why Not Chosen:**

- Over-engineered for the current requirements—adds complexity without clear benefit.
- Most production systems need JSON; providing multiple formats fragments the user base and testing matrix.
- Users can already customize behavior by configuring a custom `config.logger` that implements `info`, `warn`, `error`.
- If needed in the future, this could be added without breaking changes by introducing an adapter layer above the current implementation.

### Alternative 4: OpenTelemetry Spans

Use OpenTelemetry's span-based logging instead of discrete log events:

```ruby
OpenTelemetry.tracer_provider.tracer('activejob-temporal').in_span('job.enqueue') do |span|
  span.set_attribute('job_class', job_class)
  # ...
end
```

**Why Not Chosen:**

- Requires OpenTelemetry SDK dependency, which is heavy (~2MB) and not universally adopted.
- Span-based telemetry is complementary to logging, not a replacement—users may want both.
- OpenTelemetry is better suited for distributed tracing of workflow execution than discrete operational events like "payload too large" or "cancellation requested".
- Could be added as an optional integration later without replacing the core logging system.

## References

- [Semantic Logger Documentation](https://logger.rocketjob.io/)
- [Temporal Observability Best Practices](https://docs.temporal.io/encyclopedia/detecting-activity-failures)
- [Operational Architecture: Logging Strategy](../05_Operational_Architecture.md#logging-strategy)
