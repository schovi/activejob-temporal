# Code Refinement Task

The previous code submission did not pass verification. You must fix the following issues and resubmit your work.

---

## Original Task Description

Add optional configuration attributes to the Configuration class for production flexibility: `identity` (worker identity string for observability, default: nil), `max_payload_size_kb` (explicit payload size limit in kilobytes, default: 250). Optionally add environment variable defaults for 12-factor app compliance by reading from ENV in the initialize method: `target` from ENV['TEMPORAL_TARGET'] || '127.0.0.1:7233', `namespace` from ENV['TEMPORAL_NAMESPACE'] || 'default', `task_queue_prefix` from ENV['TEMPORAL_TASK_QUEUE_PREFIX'] || nil, `max_payload_size_kb` from ENV['TEMPORAL_MAX_PAYLOAD_SIZE_KB'] || 250. Document these new options in existing `docs/configuration_reference.md` with descriptions, types, defaults, usage examples, and environment variable mappings. Update unit tests to verify new attributes are accessible and environment variable precedence works correctly.

---

## Issues Detected

*   **Linting Error:** In `lib/activejob/temporal.rb` line 96-98, 105: Rubocop Style/StringLiterals requires double-quoted strings. Currently using single quotes for ENV variable names.
*   **Linting Error:** In `lib/activejob/temporal.rb` line 98: Rubocop Style/FetchEnvVar prefers `ENV.fetch('TEMPORAL_TASK_QUEUE_PREFIX', nil)` over `ENV['TEMPORAL_TASK_QUEUE_PREFIX']`.
*   **Linting Error:** In `lib/activejob/temporal.rb` line 105: Rubocop Style/RedundantParentheses flags redundant parentheses around the ENV expression.
*   **Linting Error:** In `spec/unit/configuration_spec.rb` lines 113-205: All test strings use single quotes instead of double quotes, violating project style guide.
*   **Configuration Issue:** Rubocop is attempting to parse `docs/configuration_reference.md` as Ruby code, which is incorrect. This file should be excluded from Rubocop checks.

---

## Best Approach to Fix

You MUST modify the following files to fix all linting errors:

### 1. Fix lib/activejob/temporal.rb (lines 96-105)

Change single quotes to double quotes for all ENV keys, use `ENV.fetch` for task_queue_prefix, and remove redundant parentheses:

```ruby
def initialize
  @target = ENV["TEMPORAL_TARGET"] || "127.0.0.1:7233"
  @namespace = ENV["TEMPORAL_NAMESPACE"] || "default"
  @task_queue_prefix = ENV.fetch("TEMPORAL_TASK_QUEUE_PREFIX", nil)
  self.default_activity_timeout = 15.minutes
  self.default_retry_initial_interval = 30.seconds
  @default_retry_backoff = 2.0
  @default_retry_max_attempts = 1
  @logger = default_logger
  @enable_tracing = true
  @max_payload_size_kb = ENV["TEMPORAL_MAX_PAYLOAD_SIZE_KB"]&.to_i || 250
  @enable_search_attributes = true
  @identity = nil
end
```

### 2. Fix spec/unit/configuration_spec.rb (lines 113-205)

Change ALL single-quoted strings to double-quoted strings in the "environment variable support" describe block. This includes:
- ENV variable names in `allow(ENV).to receive(:[]).with(...)`
- String values in `.and_return(...)`
- Expected values in `.to eq(...)`
- Directly assigned strings like `config.target = 'explicit-target:8888'`

Example pattern to follow:
```ruby
# Change from:
allow(ENV).to receive(:[]).with('TEMPORAL_TARGET').and_return('custom:9999')
expect(config.target).to eq('custom:9999')

# To:
allow(ENV).to receive(:[]).with("TEMPORAL_TARGET").and_return("custom:9999")
expect(config.target).to eq("custom:9999")
```

Apply this change to ALL strings in lines 113-205.

### 3. Run rubocop with correct file exclusion

When verifying the fix, you MUST exclude the markdown file from rubocop:

```bash
source ~/.rvm/scripts/rvm && rvm use 3.3.5 && /Users/schovi/.rvm/gems/ruby-3.3.5/bin/rubocop lib/activejob/temporal.rb spec/unit/configuration_spec.rb
```

Do NOT include `docs/configuration_reference.md` in rubocop checks.

---

## Success Criteria

After applying these fixes:

1. `source ~/.rvm/scripts/rvm && rvm use 3.3.5 && /Users/schovi/.rvm/gems/ruby-3.3.5/bin/rspec spec/unit/configuration_spec.rb` must pass with 65 examples, 0 failures
2. `source ~/.rvm/scripts/rvm && rvm use 3.3.5 && /Users/schovi/.rvm/gems/ruby-3.3.5/bin/rubocop lib/activejob/temporal.rb spec/unit/configuration_spec.rb` must report 0 offenses
3. All functional requirements from the original task remain met
