# frozen_string_literal: true

require "simplecov"

require "bundler/setup"
require "minitest/autorun"
require "minitest/spec"
require "singleton"
require "activejob/temporal"
require_relative "support/minitest_helpers"
require_relative "support/temporal_test_server"
require_relative "support/temporal_worker_test_helpers"
require_relative "support/test_state"
