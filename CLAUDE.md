# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**activejob-temporal** is a Ruby gem providing a production-ready ActiveJob adapter backed by Temporal's durable execution engine. It enables Rails applications to leverage Temporal's reliability, observability, and fault-tolerance while maintaining full ActiveJob compatibility.

### Architecture Pattern

The gem uses a **Temporal Workflow + Activity** pattern:
1. **Adapter** (`lib/activejob/temporal/adapter.rb`): Translates ActiveJob's `perform_later` calls into Temporal workflow starts
2. **Workflow** (`lib/activejob/temporal/workflows/aj_workflow.rb`): Orchestrates job execution with durable timers for scheduled jobs
3. **Activity** (`lib/activejob/temporal/activities/aj_runner_activity.rb`): Executes the actual job logic
4. **Supporting Services**: Payload serialization, retry mapping, search attributes, logging

Each enqueued job becomes a workflow execution, with optional activities for the job logic and retry handling managed through Temporal's native mechanisms.

## Key Components

- **Configuration** (`lib/activejob/temporal.rb`): DSL-style setup with explicit validation (`config.validate!`)
- **Client** (`lib/activejob/temporal/client.rb`): Temporal gRPC client builder with target/namespace/credentials handling
- **RetryMapper** (`lib/activejob/temporal/retry_mapper.rb`): Introspects ActiveJob `retry_on`/`discard_on` and converts to Temporal retry policies
- **Payload** (`lib/activejob/temporal/payload.rb`): Job argument serialization/deserialization with size validation
- **SearchAttributes** (`lib/activejob/temporal/search_attributes.rb`): Generates metadata for Temporal UI filtering
- **Logger** (`lib/activejob/temporal/logger.rb`): Structured logging with context awareness
- **Cancel** (`lib/activejob/temporal/cancel.rb`): Job cancellation API and workflow termination logic

## Development Commands

### Testing

```bash
# Run all tests (unit + integration)
bundle exec rake spec

# Unit tests only (faster feedback)
bundle exec rake spec:unit

# Integration tests only (requires Temporal running)
bundle exec rake spec:integration

# Run a specific test file
bundle exec rspec spec/unit/adapter_spec.rb

# Run a specific test example
bundle exec rspec spec/unit/adapter_spec.rb:42
```

Tests are organized by type in `spec/unit/` and `spec/integration/`. Integration tests use real Temporal workers to validate end-to-end behavior. See `spec/support/temporal_test_server.rb` for test Temporal setup.

### Linting and Code Quality

```bash
# Check for Rubocop violations
bundle exec rake rubocop

# Auto-fix violations
bundle exec rake rubocop:autocorrect

# JSON output for CI
./tools/lint.sh
```

All files must have `# frozen_string_literal: true` at the top.

### Documentation

```bash
# Generate YARD documentation
bundle exec rake yard
```

Use YARD annotations extensively:
- `@param` for arguments (include types)
- `@return` for return values
- `@raise` for exceptions
- `@example` for usage patterns
- `@note` for important caveats
- `@api private` for internal methods

### Temporal Setup (Local Development)

```bash
# Start Temporal server, UI, and PostgreSQL
docker-compose up

# Temporal UI: http://localhost:8080
# Server: localhost:7233
```

### Running a Worker

#### Local Development

For local development, run the worker directly from the gem directory:

```bash
TEMPORAL_TARGET=localhost:7233 \
TEMPORAL_NAMESPACE=default \
AJ_TEMPORAL_WORKER_QUEUE=default \
bin/temporal-worker
```

The `bin/temporal-worker` script uses relative requires to load the gem's code, so it works directly without `bundle exec`.

#### In a Rails Application

When running from a Rails application directory (not the gem directory), use `bundle exec`:

```bash
TEMPORAL_TARGET=temporal.example.com:7233 \
TEMPORAL_NAMESPACE=production \
AJ_TEMPORAL_WORKER_QUEUE=default \
RAILS_ROOT=/path/to/app \
bundle exec bin/temporal-worker
```

The `RAILS_ROOT` environment variable tells the worker to load the Rails app, so your job classes and initializers are available.

### Build and Release

```bash
# Build gem
gem build activejob-temporal.gemspec

# Full validation (Rubocop + tests)
bundle exec rake default
```

## Code Conventions

### Structure and Style

- **Module composition** over inheritance; use modules for mixins
- **Explicit requires** at top of files
- **Frozen string literals** on every file: `# frozen_string_literal: true`
- **Proper namespacing**: `ActiveJob::Temporal::Workflows::AjWorkflow`
- **Visibility markers**: Use `private` or `private_class_method` explicitly

### Naming

- **Classes**: PascalCase (`TemporalAdapter`, `AjWorkflow`)
- **Methods**: snake_case (`build_workflow_id`, `from_job`)
- **Constants**: SCREAMING_SNAKE_CASE (used sparingly)

### Error Handling

The gem uses a custom exception hierarchy rooted at `ActiveJob::Temporal::Error`:
- `ConfigurationError`: Invalid or missing configuration
- `WorkflowNotFoundError`: Job not found in Temporal
- `TemporalConnectionError`: Network or server issues

**Pattern**: Always provide human-readable error messages with context. Wrap external Temporal errors into domain-specific exceptions for cleaner error handling in client code.

### Configuration Pattern

Configuration uses a DSL pattern:

```ruby
ActiveJob::Temporal.configure do |config|
  config.target = "localhost:7233"
  config.namespace = "default"
  # Additional settings...
end

# Validation must be explicit
ActiveJob::Temporal.config.validate!
```

Configuration is validated on `validate!` call. Environment variables with defaults are used for sensitive values (e.g., `ENV.fetch("TEMPORAL_TARGET", default)`).

## Testing Patterns

### Test Organization

- **Unit tests** (`spec/unit/`): Isolated component tests with mocking/stubbing
- **Integration tests** (`spec/integration/`): End-to-end tests using real Temporal
- **Fixtures** (`spec/fixtures/sample_jobs.rb`): Sample job classes with various retry/discard configurations

### SimpleCov and Coverage

Tests use SimpleCov with branch coverage enabled. Target coverage is ≥90%. Run tests to generate coverage reports.

### Test Isolation

Use `around` hooks and shared contexts to reset state between tests. Integration tests manage Temporal workers within test lifecycle.

### Common Patterns

- Mock Temporal client responses for unit tests
- Use real workers in integration tests
- Test both success and failure paths (retries, discards)
- Validate error messages and exception types

## Workflow Implementation Notes

**Determinism**: Workflows must be deterministic—no I/O, randomness, or system time calls in the main workflow logic. Use activities for these operations.

**Durable Timers**: For scheduled jobs, workflows use Temporal's durable sleep mechanism. This persists across workflow replays and cluster restarts.

**RetryPolicy Mapping**: The `RetryMapper` introspects ActiveJob's `retry_on` and `discard_on` declarations and converts them to Temporal native retry policies. Understand this mapping when debugging job retries.

## Git Commit Conventions

Use **Conventional Commits** format: `<type>(<scope>): <description>`

**Types**:
- `feat`: New features
- `fix`: Bug fixes
- `docs`: Documentation changes
- `chore`: Maintenance, configuration, tooling
- `test`: Test additions/updates
- `refactor`: Code structure improvements (avoid in this project—prefer feature/fix commits)

**Common scopes**:
- `config`: Configuration handling
- `payload`: Job serialization
- `cancel`: Cancellation logic
- `adapter`: ActiveJob adapter
- `workflows`: Workflow implementations
- `activities`: Activity implementations
- `docs`: Documentation
- `yard`: Inline documentation
- `tasks`: Task tracking/checklists
- `ci`: CI/CD pipeline
- `release`: Release processes

**Example**: `feat(config): add worker performance tuning options`

Keep commits small and focused. A feature might consist of several commits: implementation, tests, documentation.

## Architecture Decision Records

See `docs/adr/` for recorded architectural decisions and rationale behind major design choices.

## Additional Resources

- **Configuration Reference**: `docs/configuration_reference.md`
- **Migration Guide**: `docs/migration_guide.md` (migrating from Sidekiq, Resque, etc.)
- **Worker Setup**: `docs/worker_setup.md`
- **Release Process**: `docs/publishing.md`, `docs/release_checklist.md`
- **README**: Comprehensive user guide and quick start
- **Temporal Docs**: https://docs.temporal.io/ (for workflow/activity patterns, API reference)
