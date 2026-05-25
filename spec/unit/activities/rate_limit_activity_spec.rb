# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/activities/rate_limit_activity"

RSpec.describe ActiveJob::Temporal::Activities::RateLimitActivity do
  subject(:activity) { described_class.new }

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
    expect(activity.execute({})).to eq(0.0)
  end

  it "uses limiter objects that respond to wait_time_for" do
    limiter = instance_double("RateLimiter", wait_time_for: 2.5)
    ActiveJob::Temporal.config.rate_limiter = limiter

    expect(activity.execute(payload)).to eq(2.5)
    expect(limiter).to have_received(:wait_time_for).with(payload["rate_limits"])
  end

  it "uses callable limiter objects" do
    limiter = ->(_rate_limits) { 1.25 }
    ActiveJob::Temporal.config.rate_limiter = limiter

    expect(activity.execute(payload)).to eq(1.25)
  end

  it "requires a configured limiter when rate limits are present" do
    ActiveJob::Temporal.config.rate_limiter = nil

    expect { activity.execute(payload) }
      .to raise_error(ActiveJob::Temporal::ConfigurationError, /rate_limiter is required/)
  end

  it "rejects negative wait times" do
    ActiveJob::Temporal.config.rate_limiter = ->(_rate_limits) { -1 }

    expect { activity.execute(payload) }
      .to raise_error(ArgumentError, /must not be negative/)
  end

  it "rejects non-finite wait times" do
    ActiveJob::Temporal.config.rate_limiter = ->(_rate_limits) { Float::NAN }

    expect { activity.execute(payload) }
      .to raise_error(ArgumentError, /must be finite/)
  end
end
