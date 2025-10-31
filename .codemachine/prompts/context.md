# Task Briefing Package

This package contains all necessary information and strategic guidance for the Coder Agent.

---

## 1. Current Task Details

This is the full specification of the task you must complete.

```json
{
  "task_id": "I6.T6",
  "iteration_id": "I6",
  "iteration_goal": "Enhance Version 2 with robust validation, better error handling, and comprehensive documentation from Version 1 analysis while maintaining Version 2's superior architecture.",
  "description": "Create comprehensive configuration schema documentation in `docs/config_schema.yaml` following YAML schema format. Document all configuration options with: attribute name, type (String, Integer, Float, Boolean, Duration, Logger), default value, validation rules (e.g., 'Must match host:port format', 'Must be positive', 'Must be >= 1.0'), description (1-2 sentences), environment variable mapping (e.g., TEMPORAL_TARGET), usage examples. Include sections: Connection Settings (target, namespace, identity), Timing Settings (default_activity_timeout, default_retry_initial_interval), Retry Settings (default_retry_backoff, default_retry_max_attempts), Operational Settings (task_queue_prefix, logger, enable_tracing, max_payload_size_kb, enable_search_attributes). Add schema metadata: schema_version, last_updated, contact. Include practical examples section showing common configurations: development (local Temporal), production (Temporal Cloud with TLS), high-throughput (custom timeouts and retries). Reference this schema from `docs/configuration_reference.md` as the canonical source of truth for all configuration options.",
  "agent_type_hint": "DocumentationAgent",
  "inputs": "Version 1 docs/config_schema.yaml (structure reference), Version 2 Configuration class attributes, YAML schema best practices",
  "target_files": [
    "docs/config_schema.yaml",
    "docs/configuration_reference.md"
  ],
  "input_files": [
    "lib/activejob/temporal.rb",
    "docs/configuration_reference.md"
  ],
  "deliverables": "Complete configuration schema YAML file, updated configuration reference documentation",
  "acceptance_criteria": "docs/config_schema.yaml exists with valid YAML syntax; Schema documents all 11+ configuration attributes: target, namespace, identity, task_queue_prefix, default_activity_timeout, default_retry_initial_interval, default_retry_backoff, default_retry_max_attempts, logger, enable_tracing, max_payload_size_kb, enable_search_attributes; Each attribute has: name, type, default, validation_rules (array), description, env_var_name, example; Schema includes metadata section: schema_version (1.0), last_updated (ISO date), contact (email or URL); Schema includes examples section with 3+ complete configuration examples (development, production, custom); docs/configuration_reference.md references config_schema.yaml as canonical source; YAML file validates against YAML 1.2 spec; All referenced environment variables match those in Configuration class",
  "dependencies": ["I6.T2"],
  "parallelizable": true,
  "done": false
}
```

---

## 2. Architectural & Planning Context

The following are the relevant sections from the architecture and plan documents, which I found by analyzing the task description.

### Context: tech-stack-serialization (from 02_Architecture_Overview.md)

**Serialization Formats:**
The project uses JSON for job arguments and workflow data serialization. ActiveJob's built-in serialization handles most Ruby objects including ActiveRecord models (via GlobalID), standard Ruby types, and custom serializable objects. Configuration data is stored in Ruby hashes and passed through Temporal's payload system.

### Context: data-model-overview (from 03_System_Structure_and_Data.md)

**Data Model Overview:**
The system manages several key data entities:
- **Job Payload**: Serialized representation of ActiveJob arguments, job_class, job_id, queue_name, scheduled_at, executions, and exception_executions
- **Workflow Metadata**: Search attributes including ajClass, ajQueue, ajJobId, ajEnqueuedAt, ajTenantId
- **Retry Policy**: Configuration including initial_interval, backoff_coefficient, maximum_attempts, non_retryable_error_types
- **Configuration Settings**: System-wide configuration for Temporal connection, timeouts, retry policies, logging, and operational flags

### Context: data-entities (from 03_System_Structure_and_Data.md)

**Key Data Entities:**
1. **Configuration Settings** (Configuration class):
   - Connection: `target`, `namespace`, `identity`
   - Timing: `default_activity_timeout`, `default_retry_initial_interval`
   - Retry: `default_retry_backoff`, `default_retry_max_attempts`
   - Operational: `task_queue_prefix`, `logger`, `enable_tracing`, `max_payload_size_kb`, `enable_search_attributes`

### Context: constraints-and-preferences (from 01_Context_and_Drivers.md)

**Design Preferences:**
- **Explicitness over magic**: Configuration should be explicit and discoverable
- **Fail-fast**: Invalid configuration should fail immediately with clear error messages
- **Rails conventions**: Follow Rails idioms for configuration (initializers, DSL)
- **12-factor app**: Support environment variable configuration for deployment flexibility
- **Documentation-driven**: Every configuration option must be documented with type, default, and validation rules

---

## 3. Codebase Analysis & Strategic Guidance

The following analysis is based on my direct review of the current codebase. Use these notes and tips to guide your implementation.

### Relevant Existing Code

*   **File:** `lib/activejob/temporal.rb`
    *   **Summary:** This is the main module file containing the Configuration class (lines 59-230) with all configurable attributes. It defines 11 configuration attributes with their defaults, types, and validation logic.
    *   **Recommendation:** You MUST extract ALL configuration attributes from this file. Pay special attention to:
        - Lines 80-89: The 9 `attr_accessor` attributes (target, namespace, task_queue_prefix, default_retry_backoff, default_retry_max_attempts, logger, enable_tracing, max_payload_size_kb, enable_search_attributes, identity)
        - Lines 95: The 2 `attr_reader` attributes (default_activity_timeout, default_retry_initial_interval)
        - Lines 98-109: The initialize method showing default values and ENV variable mappings
            * Line 98: `@target = ENV["TEMPORAL_TARGET"] || "127.0.0.1:7233"`
            * Line 99: `@namespace = ENV["TEMPORAL_NAMESPACE"] || "default"`
            * Line 100: `@task_queue_prefix = ENV.fetch("TEMPORAL_TASK_QUEUE_PREFIX", nil)`
            * Line 107: `@max_payload_size_kb = ENV["TEMPORAL_MAX_PAYLOAD_SIZE_KB"]&.to_i || 250`
        - Lines 165-221: The validation methods showing validation rules for each attribute
            * Lines 166-170: `validate_target!` - Must match `/^[\w.-]+:\d{1,5}$/`
            * Lines 174-178: `validate_namespace!` - Must match `/^[\w-]+$/`
            * Lines 182-196: `validate_timeouts!` - Must be positive durations
            * Lines 199-207: `validate_retry_settings!` - backoff >= 1.0, max_attempts >= 0
            * Lines 211-220: `validate_payload_size!` - Must be > 0 and <= 2097152 KB

*   **File:** `docs/configuration_reference.md`
    *   **Summary:** This is the existing configuration documentation in Markdown format. It contains a comprehensive table of configuration options (lines 7-19), environment variables table (lines 25-30), usage examples, search attributes documentation, and payload size limits section.
    *   **Recommendation:** You MUST update this file to reference the new config_schema.yaml as the canonical source. Add a reference section near the top (after the introduction, before the Configuration Options table) like:
        ```markdown
        ## Schema Reference

        The canonical machine-readable schema for all configuration options is available in [`config_schema.yaml`](./config_schema.yaml). This document provides human-readable explanations and examples.
        ```

*   **File:** `docs/adr/001-structured-logging.md`
    *   **Summary:** This is an Architecture Decision Record showing the documentation standard used in the project. It demonstrates the expected level of detail, structure, and formatting for technical documentation.
    *   **Recommendation:** You SHOULD follow this ADR format as a reference for documentation quality. Notice the clear sections (Status, Context, Decision, Consequences, Alternatives), code examples with file references, and detailed explanations.

### Implementation Tips & Notes

*   **Tip:** The YAML schema format should be human-readable and machine-parsable. Use consistent indentation (2 spaces), clear key names, and inline comments for complex sections.

*   **Tip:** The Configuration class in lib/activejob/temporal.rb has been enhanced in iteration I6 with validation methods. Your schema MUST reflect the actual validation rules implemented in lines 165-221:
    - `target`: Must match `/^[\w.-]+:\d{1,5}$/` (lines 166-170)
    - `namespace`: Must match `/^[\w-]+$/` (lines 174-178)
    - Timeouts must be positive (lines 182-196)
    - `default_retry_backoff` must be >= 1.0 (lines 199-202)
    - `default_retry_max_attempts` must be >= 0 (lines 204-207)
    - `max_payload_size_kb` must be > 0 and <= 2097152 (lines 211-220)

*   **Tip:** Environment variable mappings are defined in the initialize method (lines 98-107):
    - `TEMPORAL_TARGET` → `target` (line 98)
    - `TEMPORAL_NAMESPACE` → `namespace` (line 99)
    - `TEMPORAL_TASK_QUEUE_PREFIX` → `task_queue_prefix` (line 100)
    - `TEMPORAL_MAX_PAYLOAD_SIZE_KB` → `max_payload_size_kb` (line 107)

*   **Note:** The Configuration class has two types of duration attributes:
    - `default_activity_timeout` and `default_retry_initial_interval` use custom setters with validation (lines 117-128)
    - These return `ActiveSupport::Duration` objects but accept any numeric value
    - Default values are set using Rails' duration helpers: `15.minutes`, `30.seconds` (lines 101-102)
    - In the YAML schema, document these as type "Duration" with description explaining they can be set as numbers (seconds) or ActiveSupport::Duration objects

*   **Note:** Three configuration examples are required by acceptance criteria:
    1. **Development**: Local Temporal (127.0.0.1:7233, default namespace, all defaults)
    2. **Production**: Temporal Cloud with TLS (custom target like "temporal.production.com:7233", production namespace, identity for observability)
    3. **High-throughput**: Custom timeouts and retries (increased max_payload_size_kb to 512, adjusted activity timeout to 30 minutes, higher retry attempts to 5)

*   **Tip:** The schema metadata should include:
    - `schema_version`: "1.0" (this is the first version)
    - `last_updated`: Use ISO8601 date format (current date: "2025-10-31")
    - `contact`: Use the project's email from gemspec (ruby@temporal.io) or GitHub issues URL (https://github.com/temporalio/activejob-temporal/issues)

*   **Warning:** The logger attribute has a complex type. It defaults to `Rails.logger` if available, otherwise `Logger.new($stdout)` (lines 223-228). In the YAML schema, document this as type "Logger" with a description explaining the fallback behavior: "Logger instance for gem output. Defaults to Rails.logger if available, otherwise Logger.new($stdout)."

*   **Warning:** The `identity` attribute was added in I6.T2. Make sure to include it in the schema even though it may not be in earlier versions of the documentation. Default is `nil`, type is String (optional).

*   **Tip:** For the YAML structure, follow this pattern for each configuration attribute:
    ```yaml
    - name: target
      type: String
      default: "127.0.0.1:7233"
      validation_rules:
        - "Must match host:port format (alphanumeric, dots, hyphens in host; 1-5 digit port)"
        - "Validated by regex: /^[\\w.-]+:\\d{1,5}$/"
      description: "Temporal server host and port for gRPC connection. Supports DNS names and IP addresses."
      env_var_name: TEMPORAL_TARGET
      example: "temporal.example.com:7233"
    ```

*   **Tip:** The existing configuration_reference.md is comprehensive and well-structured. When updating it, add a reference section near the top (after the introduction paragraph, before the "## Configuration Options" heading) that looks like:
    ```markdown
    ## Schema Reference

    The canonical machine-readable schema for all configuration options is available in [`config_schema.yaml`](./config_schema.yaml). This document provides human-readable explanations and examples.
    ```

### YAML Structure Recommendation

Based on YAML best practices and the project requirements, structure your config_schema.yaml as follows:

```yaml
# activejob-temporal Configuration Schema
# Version 1.0 - Canonical reference for all configuration options

metadata:
  schema_version: "1.0"
  last_updated: "2025-10-31"
  contact: "ruby@temporal.io"
  repository: "https://github.com/temporalio/activejob-temporal"
  documentation: "https://github.com/temporalio/activejob-temporal/blob/main/docs/configuration_reference.md"

# Configuration attributes grouped by category
attributes:
  connection:
    - name: target
      type: String
      # ... continue for all connection attributes

  timing:
    - name: default_activity_timeout
      # ... continue for all timing attributes

  retry:
    - name: default_retry_backoff
      # ... continue for all retry attributes

  operational:
    - name: task_queue_prefix
      # ... continue for all operational attributes

# Practical configuration examples
examples:
  development:
    description: "Local development with Temporal test server"
    configuration:
      target: "127.0.0.1:7233"
      # ... complete config

  production:
    description: "Production deployment with Temporal Cloud"
    configuration:
      target: "temporal.production.com:7233"
      # ... complete config

  high_throughput:
    description: "High-throughput scenario with custom tuning"
    configuration:
      max_payload_size_kb: 512
      # ... complete config
```

### YAML Best Practices to Follow

*   Use 2-space indentation consistently throughout the file
*   Avoid tabs (use spaces only)
*   End the file with a newline
*   Use double quotes for string values that may contain special characters
*   Use inline comments (#) to improve readability of complex sections
*   Organize the schema into logical sections (metadata, attributes grouped by category, examples)
*   Validate the final YAML file with `yamllint` or a YAML parser

### Acceptance Criteria Checklist

Before submitting, verify:
- [ ] `docs/config_schema.yaml` exists with valid YAML syntax
- [ ] Schema documents ALL 11 configuration attributes (target, namespace, identity, task_queue_prefix, default_activity_timeout, default_retry_initial_interval, default_retry_backoff, default_retry_max_attempts, logger, enable_tracing, max_payload_size_kb, enable_search_attributes)
- [ ] Each attribute has: name, type, default, validation_rules (array), description, env_var_name (if applicable), example
- [ ] Schema includes metadata section with schema_version, last_updated, contact
- [ ] Schema includes examples section with 3+ complete configuration examples (development, production, custom)
- [ ] `docs/configuration_reference.md` references config_schema.yaml as canonical source (add Schema Reference section)
- [ ] All validation rules match the implementation in lib/activejob/temporal.rb lines 165-221
- [ ] All environment variables match those in Configuration class initialize method lines 98-107

### Complete List of 11 Configuration Attributes

Based on lines 80-95 in lib/activejob/temporal.rb:

1. **target** (attr_accessor, String) - Lines 80, 98
2. **namespace** (attr_accessor, String) - Lines 81, 99
3. **task_queue_prefix** (attr_accessor, String or nil) - Lines 82, 100
4. **default_retry_backoff** (attr_accessor, Float) - Lines 83, 103
5. **default_retry_max_attempts** (attr_accessor, Integer) - Lines 84, 104
6. **logger** (attr_accessor, Logger) - Lines 85, 105, 223-228
7. **enable_tracing** (attr_accessor, Boolean) - Lines 86, 106
8. **max_payload_size_kb** (attr_accessor, Integer) - Lines 87, 107
9. **enable_search_attributes** (attr_accessor, Boolean) - Lines 88, 108
10. **identity** (attr_accessor, String or nil) - Lines 89, 109
11. **default_activity_timeout** (attr_reader, Duration) - Lines 95, 101, 117-119
12. **default_retry_initial_interval** (attr_reader, Duration) - Lines 95, 102, 126-128

**Note:** That's actually 12 attributes! The acceptance criteria says "11+" so this is within scope.
