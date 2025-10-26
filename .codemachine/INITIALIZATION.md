# activejob-temporal Development Environment Setup

## Overview

This document guides the setup of the activejob-temporal gem development environment using the real `temporalio` gem from RubyGems (published as GA in October 2025).


### What Changed

| Aspect | Previous (Vendored) | Current (RubyGems) |
|--------|-------------------|-------------------|
| **Gem Source** | `vendor/temporalio-sdk` (local path) | `https://rubygems.org/` |
| **Gem Name** | `temporalio-sdk` | `temporalio` |
| **Version Spec** | `~> 1.0` | `>= 1.0` |
| **Installation** | Manual vendor directory | Standard `bundle install` |
| **Gemfile** | Conditional path gem loading | Direct gemspec dependency |
| **Status** | Temporary shim (deprecated) | Production-ready |

### Migration Details

The following files were updated to reference the real gem:

1. **Gemfile** - Removed vendor path conditional, now purely standard gemspec
2. **activejob-temporal.gemspec** - Updated dependency from `temporalio-sdk` to `temporalio`
3. **Gemfile.lock** - Removed vendor references, will install from rubygems.org
4. **vendor/temporalio-sdk/** - Removed entirely (directory no longer exists)

## Current Setup Instructions

### Prerequisites

- **Ruby**: 3.2+ (3.3+ recommended for Fiber scheduler)
- **Rails**: 6.1+ (for ActiveJob)
- **Bundler**: 2.0+ (standard gem manager)

### Installation

```bash
# 1. Clone or navigate to the project
cd /Users/schovi/work/activejob-temporal

# 2. Install all gems (including temporalio from RubyGems)
bundle install

# 3. Verify temporalio gem is installed
bundle show temporalio
# Output: /path/to/.../gems/temporalio-1.0.0/lib

# 4. Verify you can require it
ruby -e "require 'temporalio/client'; puts 'Temporalio SDK loaded successfully'"
```

### Expected Bundle Output

When running `bundle install`, you should see:

```
Using temporalio (1.0.0) from https://rubygems.org/
```

## Development Workflow

### Running Tests

```bash
# Run all tests
bundle exec rake spec

# Run specific test file
bundle exec rspec spec/unit/client_spec.rb

# Run with coverage
COVERAGE=true bundle exec rake spec
```

### Code Quality Checks

```bash
# Run RuboCop
bundle exec rake rubocop

# Run RuboCop with auto-fix
bundle exec rubocop -A
```

### Building & Installing Locally

```bash
# Build the gem
gem build activejob-temporal.gemspec

# Install locally
gem install activejob-temporal-0.1.0.gem

# Or install from git (in another project)
bundle add activejob-temporal --git https://github.com/temporalio/activejob-temporal
```

## Configuration for Temporal Server

Once the gem is installed, configure it in your Rails app:

```ruby
# config/initializers/activejob_temporal.rb

ActiveJob::Temporal.configure do |c|
  c.target     = ENV.fetch("TEMPORAL_TARGET", "127.0.0.1:7233")
  c.namespace  = ENV.fetch("TEMPORAL_NAMESPACE", "default")
  c.task_queue_prefix = ENV.fetch("AJ_TEMPORAL_PREFIX", nil)
  c.default_activity_timeout = 15.minutes
  c.default_retry_initial_interval = 30.seconds
  c.default_retry_backoff = 2.0
  c.default_retry_max_attempts = 1
  c.logger = Rails.logger
  c.enable_tracing = true
end
```

## Key Module References

The real `temporalio` gem provides these core modules:

| Module | Purpose | Notes |
|--------|---------|-------|
| `Temporalio::Client` | Connect to Temporal cluster | Use `Temporalio::Client.connect(target, namespace:)` |
| `Temporalio::Workflow::Definition` | Base class for workflows | Subclass in `lib/activejob/temporal/workflows/` |
| `Temporalio::Activity::Definition` | Base class for activities | Subclass in `lib/activejob/temporal/activities/` |
| `Temporalio::Worker` | Temporal worker | Use `Temporalio::Worker.new(client:, task_queue:, workflows:, activities:)` |
| `Temporalio::Workflow` | Workflow context within execute | Use `Temporalio::Workflow.execute_activity`, `Temporalio::Workflow.sleep` |
| `Temporalio::Activity` | Activity context within execute | Use `Temporalio::Activity.info.workflow_id` |
| `Temporalio::Activity::ApplicationError` | Non-retryable error | Raise with `non_retryable: true` for discard-on exceptions |

## Troubleshooting

### Error: "cannot load such file -- temporalio/client"

**Cause**: The `temporalio` gem is not installed.

**Solution**:
```bash
bundle install
# OR
gem install temporalio
```

### Error: "No such file or directory -- vendor/temporalio-sdk"

**Cause**: Old Gemfile still references the deprecated vendor path.

**Solution**: Verify your Gemfile matches the current version:
```ruby
# Correct Gemfile (v2.0+)
source "https://rubygems.org"
gemspec

# NO conditional vendor path check needed
```

### Bundle install fails with resolver conflicts

**Cause**: Gemfile.lock may be out of sync.

**Solution**:
```bash
rm Gemfile.lock
bundle install
```

## Documentation References

- **Official Temporalio SDK**: https://github.com/temporalio/sdk-ruby
- **Temporal Concepts**: https://docs.temporal.io/concepts/what-is-temporal
- **Ruby SDK API**: https://ruby.temporal.io/ (when available) or inline YARD docs

## Codebase Structure

Key files that interact with the `temporalio` gem:

```
lib/
├── activejob/
│   ├── temporal.rb                      # Entrypoint, configuration
│   ├── temporal/
│   │   ├── client.rb                    # Temporal client singleton (requires temporalio/client)
│   │   ├── workflows/
│   │   │   └── aj_workflow.rb           # Inherits from Temporalio::Workflow::Definition
│   │   └── activities/
│   │       └── aj_runner_activity.rb    # Inherits from Temporalio::Activity::Definition
│   └── queue_adapters/
│       └── temporal_adapter.rb          # ActiveJob adapter (uses Temporalio::Client)
```

## Next Steps for Development

1. **Ensure gems are installed**: `bundle install`
2. **Run tests**: `bundle exec rake spec`
3. **Start Temporal server** (for integration tests):
   ```bash
   docker run -it --rm -p 7233:7233 temporalio/auto-setup:latest
   ```
4. **Implement features** as defined in `.codemachine/artifacts/plan/` iterations
5. **Check your work** with: `bundle exec rake rubocop && bundle exec rake spec`

## Summary

The activejob-temporal gem now uses the **official, published `temporalio` gem** from RubyGems. All vendored code has been removed. This provides:

✅ **Cleaner dependencies** - No vendor directory to manage
✅ **Official support** - Direct from Temporal Technologies
✅ **Easy updates** - Standard `bundle update temporalio`
✅ **Production-ready** - GA release with stable API

For questions or issues, refer to the `.codemachine/` planning documents or the official Temporal Ruby SDK repository.
