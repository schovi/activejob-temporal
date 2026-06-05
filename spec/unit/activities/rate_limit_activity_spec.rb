# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/activities/rate_limit_activity"

describe ActiveJob::Temporal::Activities::RateLimitActivity do
  let(:activity) { described_class.new }

  let(:payload) do
    {
      "rate_limits" => [
        { "limit" => 100, "interval" => 1.0, "key" => "global" }
      ]
    }
  end

  around do |example|
    original_rate_limiter = ActiveJob::Temporal.config.rate_limiter
    original_global_rate_limit = ActiveJob::Temporal.config.global_rate_limit
    ActiveJob::Temporal.configure do |config|
      config.rate_limiter = nil
      config.global_rate_limit = nil
    end

    example.run
  ensure
    ActiveJob::Temporal.configure do |config|
      config.rate_limiter = original_rate_limiter
      config.global_rate_limit = original_global_rate_limit
    end
  end

  it "returns zero when no rate limits are present" do
    assert_equal 0.0, activity.execute({})
  end

  it "uses limiter objects that respond to wait_time_for" do
    limiter = Class.new do
      attr_reader :rate_limits

      def wait_time_for(rate_limits)
        @rate_limits = rate_limits
        2.5
      end
    end.new
    ActiveJob::Temporal.config.rate_limiter = limiter

    assert_equal 2.5, activity.execute(payload)
    assert_equal payload["rate_limits"], limiter.rate_limits
  end

  it "uses callable limiter objects" do
    limiter = ->(_rate_limits) { 1.25 }
    ActiveJob::Temporal.config.rate_limiter = limiter

    assert_equal 1.25, activity.execute(payload)
  end

  it "requires a configured limiter when rate limits are present" do
    ActiveJob::Temporal.config.rate_limiter = nil

    error = assert_raises(ActiveJob::Temporal::ConfigurationError) { activity.execute(payload) }
    assert_match(/rate_limiter is required/, error.message)
  end

  it "rejects negative wait times" do
    ActiveJob::Temporal.config.rate_limiter = ->(_rate_limits) { -1 }

    error = assert_raises(ArgumentError) { activity.execute(payload) }
    assert_match(/must not be negative/, error.message)
  end

  it "rejects non-finite wait times" do
    ActiveJob::Temporal.config.rate_limiter = ->(_rate_limits) { Float::NAN }

    error = assert_raises(ArgumentError) { activity.execute(payload) }
    assert_match(/must be finite/, error.message)
  end
end
