# frozen_string_literal: true

SimpleCov.start do
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
