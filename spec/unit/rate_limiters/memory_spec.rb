# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::RateLimiters::Memory do
  let(:clock_value) { 1000.0 }
  let(:clock) { -> { clock_value } }
  let(:limiter) { described_class.new(clock: clock) }
  let(:rate_limit) { { limit: 2, interval: 10.0, key: "api" } }

  it "allows requests until the limit is reached" do
    expect(limiter.wait_time_for([rate_limit])).to eq(0.0)
    expect(limiter.wait_time_for([rate_limit])).to eq(0.0)
  end

  it "returns the remaining wait time when the limit is reached" do
    2.times { limiter.wait_time_for([rate_limit]) }

    expect(limiter.wait_time_for([rate_limit])).to eq(10.0)
  end

  it "does not reserve capacity while a limit requires waiting" do
    2.times { limiter.wait_time_for([rate_limit]) }
    limiter.wait_time_for([rate_limit])
    allow(clock).to receive(:call).and_return(1009.0)

    expect(limiter.wait_time_for([rate_limit])).to eq(1.0)
  end

  it "enforces multiple limits atomically" do
    global_limit = { limit: 1, interval: 60.0, key: "global" }

    expect(limiter.wait_time_for([global_limit, rate_limit])).to eq(0.0)
    expect(limiter.wait_time_for([global_limit, rate_limit])).to eq(60.0)
  end

  it "records one event for duplicate key and interval limits" do
    expect(limiter.wait_time_for([rate_limit, rate_limit])).to eq(0.0)
    expect(limiter.wait_time_for([rate_limit])).to eq(0.0)
    expect(limiter.wait_time_for([rate_limit])).to eq(10.0)
  end

  it "tracks separate intervals for the same key" do
    short_limit = { limit: 2, interval: 10.0, key: "api" }
    long_limit = { limit: 3, interval: 60.0, key: "api" }

    2.times { expect(limiter.wait_time_for([short_limit, long_limit])).to eq(0.0) }

    allow(clock).to receive(:call).and_return(1011.0)

    expect(limiter.wait_time_for([short_limit, long_limit])).to eq(0.0)
    expect(limiter.wait_time_for([long_limit])).to eq(49.0)
  end

  it "requires rate limit keys" do
    expect { limiter.wait_time_for([{ limit: 1, interval: 1.0 }]) }
      .to raise_error(ArgumentError, /key must be present/)
  end
end
