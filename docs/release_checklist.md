# Release Checklist

Use this checklist before publishing a gem release or opening a release PR. It reflects the current repository state and should be updated with each release.

## Validation Commands

- [ ] `rvm 4.0.3 do bundle install`
- [ ] `rvm 4.0.3 do bundle exec rake spec`
- [ ] `rvm 4.0.3 do bundle exec rubocop`
- [ ] `rvm 4.0.3 do bundle exec rake build`
- [ ] `rvm 4.0.3 do bundle exec rake yard`

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
- [ ] RubyGems publishing credentials or trusted publishing are configured.
- [ ] The target git tag and GitHub release plan are confirmed.
- [ ] Release owner has reviewed the generated gem before publishing.
