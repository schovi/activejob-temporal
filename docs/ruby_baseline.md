# Ruby Baseline

This repository targets Ruby 4.0+ and uses Ruby 4.0.3 for local validation. Do not install Ruby 3 or use Ruby 3 as a fallback for repository tooling, dependency resolution, CI fixes, screenshots, or release checks.

## Sources Of Truth

- `.ruby-version` pins local repository tooling to `ruby-4.0.3`.
- `examples/basic_rails_app/.ruby-version` pins the example Rails app to `ruby-4.0.3`.
- `activejob-temporal.gemspec` requires Ruby `>= 4.0`.
- Root and example `Gemfile` files require Ruby `>= 4.0`.
- GitHub Actions workflows use `ruby/setup-ruby` with Ruby `4.0.3`.
- Example Dockerfiles build from Ruby `4.0.3` images.

## Local Validation

Run local commands through the Ruby 4 toolchain:

```sh
rvm 4.0.3 do bundle install
rvm 4.0.3 do bundle exec rubocop
rvm 4.0.3 do bundle exec rake spec:unit
rvm 4.0.3 do bundle exec rake build
```

For the Rails example app:

```sh
cd examples/basic_rails_app
rvm 4.0.3 do bundle exec bin/rails test
```

If Bundler, RuboCop, tests, or dependency tools fail under Ruby 4, fix the Ruby 4 path or document the external blocker. Do not lower the Ruby requirement and do not install Ruby 3 to make a tool pass.

## CI Coverage

The main CI workflow validates Ruby 4 with:

- RuboCop
- Security audit
- Unit tests
- Integration tests
- Chaos tests
- Mutation tests
- Example Rails app tests
- Gem build

The Temporal SDK compatibility workflow contract-tests Temporal Ruby SDK 1.4.0 and 1.4.1 under Ruby 4.0.3.

## External Tooling Notes

- Mutant 0.16 runs under Ruby 4, but its parser dependency may warn about an older parser version. Treat parser failures on new Ruby syntax as a mutation tooling limitation and keep repository runtime validation on Ruby 4.
- Dependabot support for Bundler projects with Ruby 4 depends on GitHub's hosted Dependabot updater. If Dependabot cannot process Ruby 4 yet, track that as an external service blocker and keep the repository baseline on Ruby 4.

## Maintenance Checklist

When changing tooling or dependencies, check:

- Ruby version files still point to Ruby 4.0.3 or newer.
- CI matrices do not add Ruby 3 jobs.
- Docker images do not downgrade below Ruby 4.
- Documentation does not ask users to install Ruby 3.
- New lockfiles record a Ruby 4 platform version.
- Release or dependency automation does not lower `required_ruby_version`.
