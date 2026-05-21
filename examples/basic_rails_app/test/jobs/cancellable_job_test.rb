# frozen_string_literal: true

require "test_helper"

class CancellableJobTest < ActiveJob::TestCase
  test "declares activity timeouts for long-running heartbeat work" do
    assert_equal 2.minutes, CancellableJob.temporal_options[:start_to_close_timeout]
    assert_equal 10.seconds, CancellableJob.temporal_options[:heartbeat_timeout]
  end
end
