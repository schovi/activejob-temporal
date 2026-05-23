# Publishing activejob-temporal to RubyGems.org

## Current Status

**Publication Status:** ⏸️ DEFERRED

The gem is **technically ready** for publication (all quality gates passed), but publication has been deferred until the required infrastructure is in place.

**Last Updated:** 2025-10-29

---

## Why Publication Was Deferred

### Infrastructure Status

1. **✅ Git Remote Configured**
   - `origin` points to `ssh://git@github.com/schovi/activejob-temporal.git`
   - Default branch is `main`

2. **✅ Gemspec Homepage Accessible**
   - Gemspec references: `https://github.com/schovi/activejob-temporal`
   - Publishing will point "Homepage" and "Source Code" links at the canonical GitHub repository

3. **❌ No RubyGems.org Account Detected**
   - No publishing credentials confirmed
   - Gemspec requires MFA: `rubygems_mfa_required: true`
   - User must set up RubyGems account with 2FA enabled

### Why These Matter

Publishing to RubyGems.org is a **one-way operation**. Once published:
- The gem version (0.1.0) is permanent and cannot be deleted
- Users will click on "Homepage" and "Source Code" links expecting to see the code
- Broken links create a poor user experience and erode trust, so repository metadata must stay verified
- RubyGems credentials must be controlled by the publishing owner and protected with MFA
- Yanking a gem is possible but discouraged and damages reputation

**Best Practice:** Ensure all infrastructure is working before making the gem public.

---

## Release Automation Policy

Release automation is intentionally not enabled yet.

The first public release must stay deliberate and manual until RubyGems ownership and publishing authentication are configured. Do not enable a workflow that publishes automatically on every push to `main`.

Future release automation should follow this policy:

1. Use a manual `workflow_dispatch` release workflow, or a protected `release` environment with required approval.
2. Prefer RubyGems trusted publishing over a long-lived `GEM_HOST_API_KEY`.
3. If `GEM_HOST_API_KEY` is used, store it only as a GitHub Actions environment secret scoped to the protected release environment.
4. Run the Ruby 4.0.3 validation gates before publishing: lint, tests, gem build, and package metadata checks.
5. Generate or verify the changelog and version bump before the irreversible publish step.
6. Create the GitHub release only after the RubyGems push succeeds.

This policy removes push-to-main publishing from scope. The remaining automation blocker is RubyGems publishing setup: either trusted publishing for this repository and workflow, or a protected release environment with `GEM_HOST_API_KEY`.

A safe interim workflow may validate release readiness without publishing. It may build the gem, inspect metadata, generate a changelog preview, and report the version that would be released. It must not push tags, publish to RubyGems, update `CHANGELOG.md`, update `lib/activejob/temporal/version.rb`, or create a GitHub release.

---

## Technical Readiness ✅

The gem itself is ready for publication:

| Quality Gate | Status | Details |
|-------------|--------|---------|
| Tests | ✅ PASSED | 115 examples, 0 failures |
| Coverage | ✅ PASSED | 99.32% line, 84.4% branch |
| Linting | ✅ PASSED | 0 Rubocop offenses |
| Documentation | ✅ COMPLETE | README, API docs, and repository guides |
| Gemspec | ✅ VALID | All metadata configured |
| Gem Build | ✅ SUCCESS | `pkg/activejob-temporal-0.1.0.gem` |
| Git Tag | ✅ CREATED | `v0.1.0` exists locally |
| Changelog | ✅ FINALIZED | v0.1.0 release notes complete |

**Release Checklist:** See `docs/release_checklist.md` for full quality audit (STATUS: APPROVED)

---

## Prerequisites for Publishing

Complete these steps before publishing:

### 1. Verify Git Remote and Push Code

```bash
# Verify remote is configured
git remote -v

# Push code to GitHub
git push -u origin main

# Push the v0.1.0 tag
git push origin v0.1.0

# Verify repository is accessible
# Visit: https://github.com/schovi/activejob-temporal
```

**Verification:**
- [ ] Code is visible at `https://github.com/schovi/activejob-temporal`
- [ ] Tag `v0.1.0` is visible in GitHub releases
- [ ] README renders correctly on GitHub

### 2. Set Up RubyGems.org Account

```bash
# Create account at https://rubygems.org/sign_up
# Enable Multi-Factor Authentication (REQUIRED by gemspec)

# Sign in locally
rvm 4.0.3 do gem signin

# Enter your RubyGems credentials when prompted
# This creates the credentials file reported by `rvm 4.0.3 do gem env`
```

**Verification:**
- [ ] RubyGems.org account created
- [ ] MFA/2FA enabled on account
- [ ] Successfully signed in via `rvm 4.0.3 do gem signin`
- [ ] Credentials file exists at the path shown by `rvm 4.0.3 do gem env`

### 3. Verify Gemspec Metadata

```bash
# Extract and verify gemspec metadata
rvm 4.0.3 do gem specification pkg/activejob-temporal-0.1.0.gem | grep -A 2 "homepage"
rvm 4.0.3 do gem specification pkg/activejob-temporal-0.1.0.gem | grep -A 2 "source_code_uri"

# Expected output:
#   homepage: https://github.com/schovi/activejob-temporal
#   source_code_uri: https://github.com/schovi/activejob-temporal
#   changelog_uri: https://github.com/schovi/activejob-temporal/blob/main/CHANGELOG.md
```

**Verification:**
- [ ] All URLs in gemspec are accessible
- [ ] Homepage loads correctly
- [ ] Source code is browsable
- [ ] Changelog is visible

---

## Publishing Procedure

Once all prerequisites are complete, follow these steps:

### Step 1: Final Pre-Publish Checks

```bash
# Ensure you're in the gem root directory
cd /Users/schovi/work/activejob-temporal

# Verify gem file exists
ls -lh pkg/activejob-temporal-0.1.0.gem

# Run final quality checks
rvm 4.0.3 do bundle exec rspec
rvm 4.0.3 do bundle exec rubocop

# Verify git tag is pushed
git ls-remote --tags origin | grep v0.1.0
```

### Step 2: Verify Package Metadata

```bash
# RubyGems 4.0.6 does not support `gem push --dry-run`.
# Validate the built package locally before the irreversible push.
rvm 4.0.3 do gem specification pkg/activejob-temporal-0.1.0.gem \
  | grep -E "^(name|version|homepage|metadata):|homepage_uri|source_code_uri|changelog_uri"

# Then confirm publishing credentials are available.
rvm 4.0.3 do gem env | grep "CREDENTIALS FILE"
```

### Step 3: Publish to RubyGems.org

```bash
# Push the gem (THIS IS IRREVERSIBLE)
rvm 4.0.3 do gem push pkg/activejob-temporal-0.1.0.gem

# Expected output:
# Pushing gem to https://rubygems.org...
# Successfully registered gem: activejob-temporal (0.1.0)
```

**⚠️ Warning:** This operation is **permanent**. The gem version 0.1.0 cannot be deleted, only yanked (which is discouraged).

### Step 4: Verify Publication

```bash
# Search for the gem
rvm 4.0.3 do gem search activejob-temporal

# Expected output:
# activejob-temporal (0.1.0)

# Visit gem page
open "https://rubygems.org/gems/activejob-temporal"

# Check gem installation works
rvm 4.0.3 do gem install activejob-temporal
rvm 4.0.3 do gem list activejob-temporal

# Test requiring the gem
rvm 4.0.3 do ruby -e "require 'activejob/temporal'; puts ActiveJob::Temporal::VERSION"
```

**Verification Checklist:**
- [ ] Gem is searchable: `rvm 4.0.3 do gem search activejob-temporal` returns results
- [ ] Gem page loads: `https://rubygems.org/gems/activejob-temporal`
- [ ] Gem can be installed: `rvm 4.0.3 do gem install activejob-temporal` succeeds
- [ ] Homepage link works (click "Homepage" on gem page)
- [ ] Source code link works (click "Source" on gem page)
- [ ] Changelog link works (click "Changelog" on gem page)
- [ ] Documentation link works (click "Documentation" on gem page)

### Step 5: Post-Publication Tasks

```bash
# Create GitHub release for v0.1.0
# Visit: https://github.com/schovi/activejob-temporal/releases/new
# - Tag: v0.1.0
# - Title: ActiveJob Temporal v0.1.0
# - Description: Copy from CHANGELOG.md
# - Attach: pkg/activejob-temporal-0.1.0.gem

# Announce the release (optional)
# - Post to Ruby community forums
# - Share on social media
# - Update documentation sites

# Monitor initial installs
# Visit: https://rubygems.org/gems/activejob-temporal
# Check download stats and user feedback
```

---

## README Installation Instructions

The README already contains the correct public gem installation instructions:

```ruby
# In your Gemfile:
gem "activejob-temporal"

# Or install directly:
gem install activejob-temporal
```

**No changes to README are needed** - the installation instructions are already correct for public gem usage.

---

## If Something Goes Wrong

### Yanking a Published Gem (Emergency Only)

```bash
# Yank a specific version (makes it unavailable for new installs)
rvm 4.0.3 do gem yank activejob-temporal -v 0.1.0

# To undo a yank:
rvm 4.0.3 do gem unyank activejob-temporal -v 0.1.0
```

**⚠️ Important:**
- Yanking should be a last resort
- Yanked gems are still visible on RubyGems with "yanked" status
- Existing installations continue to work
- Yanking damages reputation and user trust
- **DO NOT yank unless there is a security vulnerability or critical bug**

### Better Approach: Release a Patch Version

If you discover issues after publishing:
1. Fix the issues in the codebase
2. Update version to `0.1.1` in `lib/activejob/temporal/version.rb`
3. Update CHANGELOG.md with fixes
4. Build and publish the new version
5. Announce the patch release

---

## Publishing Checklist

Use this checklist when you're ready to publish:

### Infrastructure
- [ ] Git remote configured: `git remote -v` shows origin
- [ ] Code pushed to GitHub: Repository is publicly accessible
- [ ] Tag pushed: `git push origin v0.1.0` completed
- [ ] GitHub repository is publicly visible
- [ ] All gemspec URLs (homepage, source_code_uri, changelog_uri) are accessible

### RubyGems Account
- [ ] RubyGems.org account created
- [ ] Multi-Factor Authentication enabled
- [ ] Signed in locally: `rvm 4.0.3 do gem signin` completed
- [ ] Credentials file exists at the path shown by `rvm 4.0.3 do gem env`

### Quality Gates
- [ ] All tests passing: `rvm 4.0.3 do bundle exec rspec` shows 0 failures
- [ ] Code coverage adequate: >95% line coverage
- [ ] No linting offenses: `rvm 4.0.3 do bundle exec rubocop` shows 0 offenses
- [ ] Documentation complete: README, API docs, and repository guides
- [ ] Changelog finalized: `CHANGELOG.md` has v0.1.0 entry

### Gem Readiness
- [ ] Gemspec complete: All metadata fields filled
- [ ] Version set: `0.1.0` in `lib/activejob/temporal/version.rb`
- [ ] Gem builds successfully: `rvm 4.0.3 do bundle exec rake build`
- [ ] Gem file exists: `pkg/activejob-temporal-0.1.0.gem`

### Publication
- [ ] Package metadata verified locally with `gem specification`
- [ ] Gem published: `rvm 4.0.3 do gem push pkg/activejob-temporal-0.1.0.gem`
- [ ] Gem searchable: `rvm 4.0.3 do gem search activejob-temporal` returns results
- [ ] Gem page loads: Visit `https://rubygems.org/gems/activejob-temporal`
- [ ] Installation works: `rvm 4.0.3 do gem install activejob-temporal` succeeds
- [ ] All links work: Homepage, Source Code, Changelog, Documentation

### Post-Publication
- [ ] GitHub release created for v0.1.0
- [ ] Release announcement prepared (optional)
- [ ] Documentation sites updated (if applicable)
- [ ] Download stats monitored

---

## Quick Command Reference

```bash
# Check current state
git remote -v                              # Should show origin
git ls-remote --tags origin                # Should show v0.1.0
ls -lh pkg/activejob-temporal-0.1.0.gem   # Should show gem file
rvm 4.0.3 do gem specification pkg/activejob-temporal-0.1.0.gem | grep homepage

# Publishing commands
rvm 4.0.3 do gem signin                   # Sign in to RubyGems
rvm 4.0.3 do gem specification pkg/activejob-temporal-0.1.0.gem \
  | grep -E "^(name|version|homepage|metadata):|homepage_uri|source_code_uri|changelog_uri"
rvm 4.0.3 do gem push pkg/activejob-temporal-0.1.0.gem # Publish (IRREVERSIBLE)

# Verification commands
rvm 4.0.3 do gem search activejob-temporal # Search RubyGems
rvm 4.0.3 do gem install activejob-temporal # Install from RubyGems
rvm 4.0.3 do ruby -e "require 'activejob/temporal'; puts ActiveJob::Temporal::VERSION"

# Emergency commands (use with caution)
rvm 4.0.3 do gem yank activejob-temporal -v 0.1.0 # Remove from new installs
rvm 4.0.3 do gem unyank activejob-temporal -v 0.1.0 # Restore yanked gem
```

---

## Additional Resources

- **RubyGems Publishing Guide:** https://guides.rubygems.org/publishing/
- **RubyGems Best Practices:** https://guides.rubygems.org/patterns/
- **RubyGems Security:** https://guides.rubygems.org/security/
- **RubyGems MFA:** https://guides.rubygems.org/setting-up-multifactor-authentication/

---

## Contact

**Release Owner:** TBD
**Date Documentation Created:** 2025-10-29
**Gem Version:** 0.1.0
**Status:** Ready for publication once infrastructure is in place

---

**Next Steps:** Complete the prerequisites above, then follow the publishing procedure. Once published, update this document with the publication date and any lessons learned.
