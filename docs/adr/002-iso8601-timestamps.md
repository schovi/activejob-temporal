# ADR 002: ISO8601 Timestamp Format for Scheduled Jobs

## Status

Accepted

## Context

Background job scheduling requires storing future execution times in workflow payloads that are serialized to JSON and transmitted between Rails applications and Temporal workers. The `scheduled_at` field must survive serialization, network transmission, and cross-timezone execution environments.

The timestamp format must support: JSON serialization (string or number), timezone safety (unambiguous representation), human readability (no conversion tools needed), second-level precision, and cross-language compatibility (Go, Python, TypeScript). The choice impacts developer productivity, operational debugging, and payload size budgets.

## Decision

We use **ISO8601 timestamp strings with UTC timezone** for all `scheduled_at` fields in workflow payloads.

### Implementation Details

#### Serialization (Creating Payloads)

The `Payload.iso8601_timestamp` method converts Ruby Time-like objects to ISO8601 strings:

```ruby
# lib/activejob/temporal/payload.rb (lines 106-117)
def iso8601_timestamp(value)
  return value if value.is_a?(String) && valid_iso8601?(value)
  timestamp = value.respond_to?(:iso8601) ? value : value.to_time
  timestamp.iso8601
end
```

Handles multiple input types: `Time`, `DateTime`, `ActiveSupport::TimeWithZone`, or already-serialized ISO8601 strings.

**Example:**
```ruby
scheduled_time = Time.utc(2025, 10, 31, 14, 32, 18)
payload[:scheduled_at] = iso8601_timestamp(scheduled_time)
# => "2025-10-31T14:32:18Z"
```

#### Deserialization (Parsing Payloads)

The workflow parses ISO8601 timestamps using Ruby's standard library:

```ruby
# lib/activejob/temporal/workflows/aj_workflow.rb (lines 82-87)
def extract_scheduled_time(payload)
  timestamp = payload[:scheduled_at] || payload["scheduled_at"]
  return unless timestamp
  Time.iso8601(timestamp)
end
```

### Format Specification

All ISO8601 timestamps follow this pattern:

```
YYYY-MM-DDTHH:MM:SSZ

Examples:
2025-10-31T14:32:18Z  # Standard format
2025-01-01T00:00:00Z  # Midnight UTC
2025-12-31T23:59:59Z  # End of year
```

- **Date Component**: `YYYY-MM-DD` (zero-padded)
- **Time Separator**: `T` (uppercase)
- **Time Component**: `HH:MM:SS` (24-hour format, zero-padded)
- **Timezone**: `Z` (Zulu time = UTC, always uppercase)
- **No Milliseconds**: Precision stops at seconds
- **No Timezone Offset**: Always use `Z`, never `+00:00` or local offsets

## Consequences

### Positive

- **Debugging Clarity**: Developers can immediately understand when jobs are scheduled by reading workflow histories or JSON payloads:
  ```json
  {"scheduled_at": "2025-10-31T14:32:18Z"}
  ```
  vs. Unix timestamp requiring conversion:
  ```json
  {"scheduled_at": 1730386338}
  ```

- **Timezone Unambiguity**: The explicit `Z` suffix removes all timezone interpretation ambiguity. There's no risk of a parser incorrectly applying local timezone offset.

- **Log Correlation**: Timestamps in logs match timestamps in payloads (both use ISO8601), making it easier to correlate scheduled times across systems.

- **Standards Compliance**: ISO8601 (RFC 3339 profile) is an internationally recognized standard supported by all major programming languages and databases.

- **Rails Integration**: `Time.iso8601()` is part of Ruby's standard library, requiring no additional dependencies. ActiveSupport extends this with timezone-aware parsing.

- **Temporal SDK Compatibility**: The Temporalio Ruby SDK expects Time objects for `Workflow.now` and `Workflow.sleep`, which integrate seamlessly with `Time.iso8601()` parsing.

### Negative

- **Payload Size Overhead**: ISO8601 strings (~20 bytes) are 2x larger than Unix timestamps (~10 bytes), though negligible for typical single-timestamp payloads.
- **No Sub-Second Precision**: Format excludes milliseconds/microseconds.
- **String Parsing Overhead**: Parsing ISO8601 (~2-3µs) is slower than Unix timestamp coercion (~0.5µs), negligible except in >100K jobs/second systems.

## Alternatives Considered

### Alternative 1: Unix Timestamps (Integer Seconds Since Epoch)

Store `scheduled_at` as integer seconds since Unix epoch (January 1, 1970 UTC):

```ruby
# Serialization
payload[:scheduled_at] = scheduled_time.to_i  # => 1730386338

# Deserialization
Time.at(payload[:scheduled_at])  # => 2025-10-31 14:32:18 UTC
```

**Why Not Chosen:**

- **Debugging Friction**: Developers would need to convert timestamps during incident response:
  ```bash
  # What does 1730386338 mean?
  $ date -r 1730386338
  # => Thu Oct 31 14:32:18 UTC 2025
  ```
  This adds cognitive load and slows down troubleshooting.

- **Timezone Ambiguity Risk**: While Unix timestamps are conventionally UTC, the integer itself carries no timezone information. A careless parser could misinterpret it as local time.

- **Limited Benefits**: The 10-byte savings per timestamp is trivial compared to the overall payload size budget (250KB default). Most job payloads are dominated by serialized arguments, not timestamps.

### Alternative 2: Unix Timestamps with Milliseconds (Float)

Use floating-point for fractional seconds. **Why Not Chosen:** Unnecessary precision (job scheduling uses minutes/hours), floating-point rounding errors, still not human-readable.

### Alternative 3: ISO8601 with Timezone Offsets

Preserve local timezone offsets (`2025-10-31T09:32:18-05:00`) instead of UTC. **Why Not Chosen:** Workers in different timezones create ambiguity, offset adds 6 characters vs. 1 for `Z`, background jobs are timezone-agnostic.

## References

- [ISO8601 Standard (Wikipedia)](https://en.wikipedia.org/wiki/ISO_8601)
- [RFC 3339: Date and Time on the Internet](https://tools.ietf.org/html/rfc3339)
- [Ruby Time.iso8601 Documentation](https://docs.ruby-lang.org/en/master/Time.html#method-c-iso8601)
- [Temporal Workflow Time Handling](https://docs.temporal.io/workflows#wall-clock-time)
- [System Structure: Data Model](../03_System_Structure_and_Data.md#data-model)
