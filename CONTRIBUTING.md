# Contributing

## Ruby Baseline

Use Ruby 4.0.3 for local development and validation. The repository targets Ruby 4+ and does not require installing Ruby 3.

See [Ruby Baseline](docs/ruby_baseline.md) for the source-of-truth files, CI coverage, and external tooling notes.

Run validation commands through the Ruby 4 toolchain:

```sh
rvm 4.0.3 do bundle install
rvm 4.0.3 do bundle exec rake spec:unit
rvm 4.0.3 do bundle exec rubocop
rvm 4.0.3 do bundle exec rake build
```

## Mutation Testing

Mutation testing runs a scoped Mutant baseline against deterministic unit-level code:

```sh
rvm 4.0.3 do bundle exec rake mutation
```

The default subject list is intentionally small so the task stays fast and does not require a local Temporal server. Expand `.mutant.yml` as specs are hardened around additional code paths.

Mutant 0.16 supports Ruby 4, but its parser dependency may warn about an older parser version. Treat new Ruby syntax parse failures as a Mutant tooling limitation and keep the repository runtime baseline on Ruby 4.

## Dependency Updates

Dependabot checks root Bundler dependencies weekly and opens up to five update pull requests at a time.

Development dependency minor and patch updates are grouped into a single pull request. Review dependency pull requests like any other change: confirm CI passes, scan the changelog for breaking behavior, and keep major updates separate unless the dependency explicitly documents compatibility.

## Code Quality Tracking

Qlty, the successor to Code Climate Quality, reads the committed `.qlty/qlty.toml` analysis configuration.

The current configuration focuses maintainability tracking on the library code and excludes generated or packaged artifacts. RuboCop findings are monitored in Qlty while the existing GitHub Actions lint job remains the blocking local validation path.

Do not add a README maintainability badge until the repository has been added to Qlty and the generated project badge URL is available.

## Changelog

Generate release changelog updates from merged GitHub pull requests and closed issues:

```sh
CHANGELOG_GITHUB_TOKEN=... rvm 4.0.3 do bundle exec rake changelog:generate
```

The task also accepts `GITHUB_TOKEN` when `CHANGELOG_GITHUB_TOKEN` is not set. Review the generated `CHANGELOG.md` before committing release notes.

Generated unreleased sections are rebuilt from GitHub issues and pull requests. Existing released sections stay in place so curated release notes are not lost.

## Release Commits

Release automation is not enabled yet.

Use conventional commit prefixes where they describe the change:

- `feat:` for user-visible features
- `fix:` for bug fixes
- `docs:` for documentation-only changes
- `test:` for test-only changes
- `ci:` for GitHub Actions or CI changes
- `chore:` for maintenance that does not affect runtime behavior

Do not rely on commit messages to publish a release until [Publishing](docs/publishing.md) says release automation is enabled.
