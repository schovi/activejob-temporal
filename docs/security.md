# Security

This document outlines security practices for the activejob-temporal gem.

## Dependency Management

### Vulnerability Scanning

We use `bundle-audit` to automatically check for known vulnerabilities in gem dependencies:

```bash
# Local scan
rvm 4.0.3 do bundle-audit check --update

# CI automatically scans on each push/PR
```

Vulnerabilities are tracked in `.github/workflows/ci.yml` and block merges.

### Updating Dependencies

To update gems safely:

```bash
# Update all gems
rvm 4.0.3 do bundle update

# Update specific gem
rvm 4.0.3 do bundle update rails

# Run security check after updating
./tools/security-check.sh
```

### Dependency Constraints

See `activejob-temporal.gemspec` for version constraints:

```ruby
spec.add_dependency "activejob", ">= 7.2", "< 9"
spec.add_dependency "activemodel", ">= 7.2", "< 9"
spec.add_dependency "concurrent-ruby", "~> 1.1"
spec.add_dependency "globalid", ">= 0.3"
spec.add_dependency "temporalio", ">= 1.4.1"
```

Conservative constraints prevent unpredictable breaking changes.

## Code Security

### Input Validation and Sanitization

The gem takes the following security measures:

#### Job Cancellation (Query Injection Prevention)

The `Cancel` module builds Temporal search queries using the job class name and job_id. To prevent query injection attacks:

1. **UUID Validation**: All job_id values are validated to match RFC 4122 UUID format before use
2. **Safe Character Set**: UUIDs contain only hexadecimal characters and hyphens `[0-9a-fA-F-]`, making the job_id safe for query interpolation
3. **Early Rejection**: Invalid job_id values raise `ArgumentError` before any queries are executed

```ruby
# ✅ Valid UUID - accepted
ActiveJob::Temporal.cancel(MyJob, "550e8400-e29b-41d4-a716-446655440000")

# ❌ Invalid format - rejected with ArgumentError
ActiveJob::Temporal.cancel(MyJob, "test' OR '1'='1")  # Query injection attempt blocked
```

**Rationale**: While ActiveJob auto-generates UUIDs, the `cancel()` method is a public API that accepts arbitrary job_id values. Validation prevents search query injection in multi-tenant environments.

Batch cancellation accepts only the gem's known search attributes (`ajClass`, `ajQueue`, `ajJobId`, `ajEnqueuedAt`, `ajTenantId`). String values are quoted before query construction, and `ajTenantId` must be an integer.

Status inspection uses the same UUID validation for job IDs before building Temporal visibility queries.

#### General Security Practices

The gem does **not**:
- ❌ Execute user code directly
- ❌ Build SQL queries from user input (except validated Temporal search queries as above)
- ❌ Render user input in HTML
- ❌ Execute shell commands with job arguments

All job arguments are serialized to JSON/GlobalID and passed through Temporal safely.

### TLS Certificate Validation

When using TLS with Temporal:

```ruby
# ✅ Load from secure environment variable
ENV["TEMPORAL_TLS_CERT"]  # Should be set in secure config, not code

# ❌ Don't hardcode certificates
config.tls_cert_path = "/path/to/cert"  # OK if path is secure
```

### Payload Serialization

Job arguments are serialized securely:

1. **No arbitrary code execution**: Uses `ActiveJob::Arguments.serialize`
2. **Size limits**: Payloads > 250KB rejected (prevents DoS)
3. **GlobalID support**: References instead of full object serialization

```ruby
# ✅ Serialization via GlobalID
MyModel.new(id: 123)
# Serialized as: "gid://app/MyModel/123"

# ❌ Full object serialization (don't do)
# That would try to serialize entire object state
```

## Logging & Observability

### Structured Logging

We use structured JSON logging to avoid leaking sensitive data in plaintext logs.

Logs include:
- ✅ workflow_id, job_class, job_id, queue, status
- ❌ Job arguments (too sensitive)
- ❌ Retry backoff details (implementation detail)

## Security Reporting

To report security vulnerabilities privately:

1. **DO NOT** open a public GitHub issue
2. **DO** email the maintainers with details:
   - Description of vulnerability
   - Affected versions
   - Proof of concept (if possible)
3. Maintainers will:
   - Confirm and assess severity
   - Release patch within 30 days
   - Credit reporter (if desired)

## CI Security Scanning

### Automated Checks

Every push and pull request runs:
- **bundle-audit**: Scans Gemfile.lock for known CVEs in dependencies
- Blocks merge if vulnerabilities are found

### Local Security Checks

Run security checks locally before committing:

```bash
./tools/security-check.sh
```

This script:
1. Installs bundle-audit if needed
2. Updates vulnerability database
3. Scans dependencies for known issues
4. Optionally runs Brakeman (if installed)

### Dependency Update Strategy

- **Security patches**: Apply immediately (e.g., Rails 7.2.1 → 7.2.2)
- **Minor updates**: Apply quarterly (e.g., Rspec 3.12 → 3.13)
- **Major updates**: Plan carefully (e.g., Rails 7 → 8)

### Update Process

1. Update Gemfile
2. Run `rvm 4.0.3 do bundle update`
3. Run local tests: `rvm 4.0.3 do bundle exec rake spec:unit`
4. Run security check: `./tools/security-check.sh`
5. Commit and create PR
6. Wait for CI to pass
7. Merge and release

## Known Vulnerabilities

Currently: **0 known vulnerabilities**

Last scanned: [Auto-updated in CI]

## Related

- [Temporal Security Best Practices](https://docs.temporal.io/security)
- [Rails Security Guide](https://guides.rubyonrails.org/security.html)
- [Ruby Security Best Practices](https://guides.ruby-lang.org/security.html)
