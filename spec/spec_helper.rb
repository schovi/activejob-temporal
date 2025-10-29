# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  enable_coverage :branch

  # Enable result merging for separate test runs (unit + integration)
  command_name "RSpec:#{ENV['TEST_SUITE'] || 'all'}"
  merge_timeout 3600 # 1 hour
end

require "bundler/setup"
require "activejob/temporal"
require_relative "support/temporal_test_server"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
    expectations.syntax = :expect
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.order = :random

  Kernel.srand config.seed
end
