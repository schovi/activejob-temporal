# Release Checklist

Use this checklist before publishing a gem release or opening a release PR. It reflects the current repository state and should be updated with each release.

## Validation Commands

- [ ] `rvm 4.0.3 do bundle install`
- [ ] `BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile rvm 4.0.3 do bundle exec rake spec:unit`
- [ ] `BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile rvm 4.0.3 do bundle exec rake spec:integration`
- [ ] `BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile rvm 4.0.3 do bundle exec rake spec:contract`
- [ ] `BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile rvm 4.0.3 do bundle exec rake spec:chaos`
- [ ] `BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile rvm 4.0.3 do bundle exec rake rubocop`
- [ ] `BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile rvm 4.0.3 do bundle exec bundle-audit check --update`
- [ ] `BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile rvm 4.0.3 do bundle exec rake mutation`
- [ ] `BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile rvm 4.0.3 do bundle exec rake build`
- [ ] `BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile rvm 4.0.3 do bundle exec ruby tools/ci/verify_gem_package.rb pkg/activejob-temporal-*.gem`
- [ ] `BUNDLE_GEMFILE=gemfiles/rails_8_1.gemfile rvm 4.0.3 do bundle exec rake yard`
- [ ] `cd examples/basic_rails_app && RAILS_ENV=test rvm 4.0.3 do bundle exec rails db:prepare`
- [ ] `cd examples/basic_rails_app && RAILS_ENV=test rvm 4.0.3 do bundle exec rails test`
- [ ] `cd examples/basic_rails_app && rvm 4.0.3 do bundle exec bin/rubocop`
- [ ] `cd examples/basic_rails_app && rvm 4.0.3 do bundle exec bin/brakeman --no-pager --quiet`

## Documentation Review

- [ ] README setup, configuration, worker, retry, orchestration, and constraint sections are current.
- [ ] Configuration reference and `docs/config_schema.yaml` agree with the code.
- [ ] Worker setup, troubleshooting, performance tuning, retry, metrics, recurring jobs, and Nexus docs match current behavior.
- [ ] Publishing instructions match the intended release path.

## Functional Review

- [ ] Enqueue starts `AjWorkflow` with expected workflow IDs and search attributes.
- [ ] Scheduled jobs use durable workflow sleeps.
- [ ] `retry_on` and `discard_on` map to Temporal retry policies.
- [ ] Duplicate enqueue behavior is intentional and covered.
- [ ] Cancellation, signal/query/update handlers, and inspection APIs work.
- [ ] Chains, child workflows, dependencies, recurring schedules, dead letter workflows, continue-as-new, local activity helpers, and Nexus boundaries are documented and covered where applicable.

## Real Constraints

- [ ] Payload size limit is documented and enforced.
- [ ] General DAG orchestration is not supported beyond chains, child workflows, and dependency gates.
- [ ] Symbol and Proc retry waits fall back to numeric Temporal retry policy settings.
- [ ] Long-running activities need cooperative heartbeating or cancellation checks.
- [ ] Nexus remains an explicit workflow-layer boundary until the Ruby SDK exposes worker-side Nexus handler registration.

## Publishing Gates

- [ ] Version, changelog, and gemspec metadata are correct.
- [ ] `git describe --tags --exact-match HEAD` returns the tag being released.
- [ ] The tag name equals `v#{ActiveJob::Temporal::VERSION}`.
- [ ] RubyGems publishing credentials or trusted publishing are configured.
- [ ] The target git tag and GitHub release plan are confirmed.
- [ ] Release owner has reviewed the generated gem before publishing.
