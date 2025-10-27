# activejob-temporal

> Temporal-powered adapter for Rails ActiveJob.

⚠️ This gem is under active development. Expect rapid iteration and potential breaking changes until v1.0.0.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "activejob-temporal"
```

And then execute:

```bash
bundle install
```

## Usage

Configure ActiveJob to use the Temporal adapter in your Rails application:

```ruby
# config/application.rb
config.active_job.queue_adapter = :temporal
```

Configure the Temporal client during application boot:

```ruby
# config/initializers/active_job_temporal.rb
ActiveJob::Temporal.configure do |config|
  config.target = ENV.fetch("TEMPORAL_TARGET", "127.0.0.1:7233")
  config.namespace = ENV.fetch("TEMPORAL_NAMESPACE", "default")
  config.task_queue_prefix = ENV.fetch("TEMPORAL_TASK_QUEUE_PREFIX", nil)
end
```

More usage documentation, including workflow orchestration examples, is coming soon.

## Development

After checking out the repo, run `bundle install`, `bundle exec rake rubocop`, and `bundle exec rake spec` to verify the toolchain.

## License

MIT. See [LICENSE](LICENSE).
