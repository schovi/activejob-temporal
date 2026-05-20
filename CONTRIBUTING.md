# Contributing

## Ruby Baseline

Use Ruby 4.0.3 for local development and validation. The repository targets Ruby 4+ and does not require installing Ruby 3.

Run validation commands through the Ruby 4 toolchain:

```sh
rvm 4.0.3 do bundle install
rvm 4.0.3 do bundle exec rake spec:unit
rvm 4.0.3 do bundle exec rubocop
rvm 4.0.3 do bundle exec rake build
```

## Dependency Updates

Dependabot checks root Bundler dependencies weekly and opens up to five update pull requests at a time.

Development dependency minor and patch updates are grouped into a single pull request. Review dependency pull requests like any other change: confirm CI passes, scan the changelog for breaking behavior, and keep major updates separate unless the dependency explicitly documents compatibility.
