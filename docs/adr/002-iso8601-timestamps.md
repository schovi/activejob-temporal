# ADR 002: ISO8601 Timestamp Format for Scheduled Jobs

## Status

Accepted

## Context

Background job scheduling requires storing future execution times in workflow payloads that are serialized to JSON and transmitted between Rails applications and Temporal workers. The `scheduled_at` field represents when a delayed job should execute, and this timestamp must survive serialization, network transmission, and cross-timezone execution environments.

### Requirements

1. **JSON Serialization**: Timestamps must be representable as JSON primitive types (string or number), as Ruby Time objects cannot be directly serialized to JSON.

2. **Timezone Safety**: Rails applications may run in different timezones than Temporal workers. The timestamp format must unambiguously represent a specific moment in time regardless of the parsing environment's local timezone.

3. **Human Readability**: Developers need to inspect payloads during debugging and incident response. Timestamps in workflow histories should be immediately understandable without conversion tools.

4. **Precision Requirements**: Job scheduling requires second-level precision. Sub-second precision (milliseconds, microseconds) is not necessary for typical background job use cases.

5. **Cross-Language Compatibility**: While the current implementation is Ruby-only, Temporal workflows may eventually include activities written in other languages (Go, Python, TypeScript). The timestamp format should use a widely-supported standard.

6. **Payload Size Constraints**: Temporal enforces a 2MB limit on workflow history size. Every field in the payload contributes to this limit, so timestamp representation should balance readability with compactness.

### The Problem Space

Three primary options exist for representing timestamps in JSON:

1. **Unix Timestamps (Integer)**: Seconds since epoch (e.g., `1730386338`)
   - Compact (10 digits for dates through 2286)
   - Requires timezone interpretation (typically assumed UTC)
   - Completely opaque to humans without conversion

2. **Unix Timestamps with Milliseconds (Float)**: Fractional seconds (e.g., `1730386338.254`)
   - Slightly larger (~13 characters)
   - Precision beyond typical scheduling needs
   - Still opaque to humans

3. **ISO8601 Strings**: Standardized date-time format (e.g., `"2025-10-31T14:32:18Z"`)
   - Self-documenting timezone (Z = UTC)
   - Human-readable
   - Larger size (~20-25 characters)
   - Industry standard (RFC 3339)

The choice impacts developer productivity, operational debugging, and payload size budgets.

## Decision

We use **ISO8601 timestamp strings with UTC timezone** for all `scheduled_at` fields in workflow payloads.

### Implementation Details

#### Serialization (Creating Payloads)

The `Payload.iso8601_timestamp` method converts Ruby Time-like objects to ISO8601 strings:

```ruby
# lib/activejob/temporal/payload.rb (lines 106-117)

def iso8601_timestamp(value)
  return value if value.is_a?(String) && valid_iso8601?(value)

  timestamp = if value.respond_to?(:iso8601)
                value
              elsif value.respond_to?(:to_time)
                value.to_time
              else
                raise ArgumentError, "scheduled_at must be convertible to Time"
              end
  timestamp.iso8601
end
```

This method is called when creating payloads for scheduled jobs:

```ruby
# lib/activejob/temporal/payload.rb (lines 60-72)

payload = {
  job_class: job.class.name,
  job_id: job.job_id,
  queue_name: job.queue_name,
  arguments: serialize_arguments(job.arguments || []),
  executions: job.executions || 0,
  exception_executions: job.exception_executions || {}
}
payload[:scheduled_at] = iso8601_timestamp(scheduled_at) if scheduled_at

enforce_payload_size!(payload)
payload
```

**Example Output:**

```ruby
scheduled_time = Time.utc(2025, 10, 31, 14, 32, 18)
payload = Payload.from_job(job, scheduled_at: scheduled_time)

payload[:scheduled_at]
# => "2025-10-31T14:32:18Z"
```

The serializer handles multiple input types gracefully:

- `Time` objects: Directly call `.iso8601`
- `DateTime` objects: Convert via `.to_time.iso8601`
- `ActiveSupport::TimeWithZone` objects: Convert via `.to_time.iso8601`
- Already-serialized strings: Pass through if valid ISO8601 format

#### Deserialization (Parsing Payloads)

The workflow extracts and parses ISO8601 timestamps using Ruby's standard library:

```ruby
# lib/activejob/temporal/workflows/aj_workflow.rb (lines 82-87)

def extract_scheduled_time(payload)
  timestamp = payload[:scheduled_at] || payload["scheduled_at"]
  return unless timestamp

  Time.iso8601(timestamp)
end
```

This parsed Time object is then used to calculate sleep duration:

```ruby
# lib/activejob/temporal/workflows/aj_workflow.rb (lines 89-94)

def sleep_until(target_time)
  now = Temporalio::Workflow.now
  delay = target_time - now
  return unless delay.positive?

  Temporalio::Workflow.sleep(delay)
end
```

**Complete Execution Flow:**

```ruby
# In Rails application (enqueue side):
job = MyJob.set(wait_until: 5.minutes.from_now)
# => scheduled_at: "2025-10-31T14:37:18Z"

# In Temporal workflow (execution side):
scheduled_time = extract_scheduled_time(payload)
# => Time.utc(2025, 10, 31, 14, 37, 18)

sleep_until(scheduled_time)
# => Temporalio::Workflow.sleep(300) # 5 minutes = 300 seconds
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

- **Payload Size Overhead**: ISO8601 strings are significantly larger than Unix timestamps:
  - ISO8601: `"2025-10-31T14:32:18Z"` = 20 characters = ~20 bytes
  - Unix timestamp: `1730386338` = 10 characters = ~10 bytes
  - **Overhead**: ~10 bytes per timestamp (2x size)

  For typical jobs with a single `scheduled_at` field, this adds negligible overhead. However, if payloads included arrays of timestamps, the overhead would multiply.

- **No Sub-Second Precision**: The format excludes milliseconds/microseconds. If future requirements need sub-second scheduling precision, the format would need to change to include fractional seconds:
  ```
  "2025-10-31T14:32:18.254Z"  # With milliseconds (not currently used)
  ```

- **String Parsing Overhead**: Parsing ISO8601 strings is computationally more expensive than integer coercion:
  ```ruby
  # ISO8601 parsing (used)
  Time.iso8601("2025-10-31T14:32:18Z")  # ~2-3 microseconds

  # Unix timestamp parsing (alternative)
  Time.at(1730386338)                   # ~0.5 microseconds
  ```
  This difference is negligible for individual jobs but could matter in extremely high-throughput systems (>100K jobs/second).

- **Manual String Construction Complexity**: If developers need to manually construct timestamps (e.g., in tests or data migrations), ISO8601 requires more careful formatting than simple integers. However, the `iso8601_timestamp` helper mitigates this by accepting Time objects.

### Neutral

- **Lexicographic Sorting**: ISO8601 strings sort correctly when compared as strings, which can be useful for debugging but isn't a primary requirement:
  ```ruby
  ["2025-10-30T12:00:00Z", "2025-10-31T14:32:18Z"].sort
  # => Correctly ordered chronologically
  ```

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

Use floating-point numbers to represent fractional seconds:

```ruby
# Serialization
payload[:scheduled_at] = scheduled_time.to_f  # => 1730386338.254

# Deserialization
Time.at(payload[:scheduled_at])  # => 2025-10-31 14:32:18.254 UTC
```

**Why Not Chosen:**

- **Unnecessary Precision**: Background job scheduling doesn't require sub-second precision. Jobs are typically scheduled for minutes, hours, or days in the future—millisecond precision adds no value.

- **Floating-Point Precision Issues**: Representing large integers (Unix timestamps) as floats can introduce rounding errors in some languages:
  ```javascript
  // JavaScript example
  1730386338254  // Integer milliseconds
  1730386338.254 * 1000  // => 1730386338254.0000002 (floating-point error)
  ```

- **Still Not Human-Readable**: Shares the same debugging friction as integer Unix timestamps.

### Alternative 3: Separate Date and Time Fields

Store date and time as separate fields:

```ruby
payload[:scheduled_date] = "2025-10-31"
payload[:scheduled_time] = "14:32:18"
payload[:scheduled_timezone] = "UTC"
```

**Why Not Chosen:**

- **Increased Payload Size**: Three fields instead of one, actually *larger* than ISO8601.

- **Reconstruction Complexity**: Parsing requires reassembling the components:
  ```ruby
  Time.utc(date.year, date.month, date.day, time.hour, time.min, time.sec)
  ```

- **No Standards Compliance**: Custom format requires documentation and increases onboarding time.

### Alternative 4: ISO8601 with Timezone Offsets

Use ISO8601 but preserve local timezone offsets instead of normalizing to UTC:

```ruby
payload[:scheduled_at] = scheduled_time.iso8601  # => "2025-10-31T09:32:18-05:00"
```

**Why Not Chosen:**

- **Timezone Complexity**: Temporal workers may run in different timezones than the Rails application. Preserving offsets creates ambiguity:
  - What if a worker doesn't support the specified timezone?
  - Should the offset be interpreted or converted to UTC?

- **Larger Payload**: Offset notation (`-05:00`, `+01:00`) adds 6 characters vs. 1 character for `Z`.

- **No Clear Benefit**: Background jobs execute in a timezone-agnostic context (Temporal workers). The original local time is irrelevant—only the absolute moment matters.

## References

- [ISO8601 Standard (Wikipedia)](https://en.wikipedia.org/wiki/ISO_8601)
- [RFC 3339: Date and Time on the Internet](https://tools.ietf.org/html/rfc3339)
- [Ruby Time#iso8601 Documentation](https://ruby-doc.org/stdlib-3.0.0/libdoc/time/rdoc/Time.html#method-i-iso8601)
- [Temporal Workflow Time Handling](https://docs.temporal.io/workflows#wall-clock-time)
- [System Structure: Data Model](../03_System_Structure_and_Data.md#data-model)
