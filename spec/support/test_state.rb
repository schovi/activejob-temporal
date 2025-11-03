# frozen_string_literal: true

# Thread-safe test state container for integration tests.
#
# Replaces global variables with a proper singleton pattern that can be
# accessed from different threads (e.g., Temporal worker threads).
#
# @example Basic usage
#   TestState.instance.reset!
#   TestState.instance.attempt_count += 1
#   expect(TestState.instance.test_result).to eq("success")
class TestState
  include Singleton

  attr_accessor :attempt_count,
                :test_result,
                :discard_test_executed,
                :long_running_iterations,
                :long_running_completed,
                :custom_timeout_executed

  def initialize
    reset!
  end

  # Resets all state to default values
  def reset!
    @attempt_count = 0
    @test_result = nil
    @discard_test_executed = false
    @long_running_iterations = 0
    @long_running_completed = false
    @custom_timeout_executed = false
  end
end
