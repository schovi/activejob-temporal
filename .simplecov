# frozen_string_literal: true

if ENV["CI"]
  require "simplecov-lcov"

  SimpleCov::Formatter::LcovFormatter.config do |config|
    config.report_with_single_file = true
    config.single_report_path = "coverage/lcov.info"
  end
end

SimpleCov.start do
  if ENV["CI"]
    ci_formatters = [
      SimpleCov::Formatter::HTMLFormatter,
      SimpleCov::Formatter::LcovFormatter
    ]

    formatter SimpleCov::Formatter::MultiFormatter.new(ci_formatters)
  end

  add_filter "/spec/"
  enable_coverage :branch

  command_name "RSpec:#{ENV.fetch('TEST_SUITE', 'all')}"
  merge_timeout 3600

  add_group "Core", "lib/activejob/temporal.rb"
  add_group "Adapter", "lib/activejob/temporal/adapter.rb"
  add_group "Workflows", "lib/activejob/temporal/workflows"
  add_group "Activities", "lib/activejob/temporal/activities"
  add_group "Services", %w[
    lib/activejob/temporal/workflow_enqueuer.rb
    lib/activejob/temporal/retry_mapper.rb
    lib/activejob/temporal/payload.rb
  ]
  add_group "Configuration", %w[
    lib/activejob/temporal/configuration.rb
    lib/activejob/temporal/temporal_options.rb
  ]
end
