# frozen_string_literal: true

require "simplecov"

require "bundler/setup"
require "singleton"
require "activejob/temporal"
require_relative "support/temporal_test_server"
require_relative "support/test_state"

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
