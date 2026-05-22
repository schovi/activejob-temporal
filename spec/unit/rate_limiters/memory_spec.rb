# frozen_string_literal: true

require "spec_helper"
require "timeout"

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

  it "does not block unrelated keys while another key is active" do
    slow_limit = { limit: 10, interval: 10.0, key: "slow" }
    fast_limit = { limit: 10, interval: 10.0, key: "fast" }
    slow_entered = Queue.new
    release_slow = Queue.new
    original_active_timestamps = limiter.method(:active_timestamps)
    slow_blocked = false

    limiter.define_singleton_method(:active_timestamps) do |rate_limit, now, bucket|
      if rate_limit[:key] == "slow" && !slow_blocked
        slow_blocked = true
        slow_entered << true
        release_slow.pop
      end

      original_active_timestamps.call(rate_limit, now, bucket)
    end

    slow_thread = Thread.new { limiter.wait_time_for([slow_limit]) }
    slow_entered.pop

    fast_thread = Thread.new { limiter.wait_time_for([fast_limit]) }

    expect(Timeout.timeout(1) { fast_thread.value }).to eq(0.0)
  ensure
    release_slow << true if release_slow
    slow_thread&.join
    fast_thread&.join
  end

  it "evicts idle buckets when their timestamps expire without recording new capacity" do
    blocking_limit = { limit: 1, interval: 60.0, key: "global" }
    idle_limit = { limit: 1, interval: 10.0, key: "tenant-1" }
    limiter.wait_time_for([blocking_limit])
    limiter.wait_time_for([idle_limit])
    allow(clock).to receive(:call).and_return(1011.0)

    expect(limiter.wait_time_for([blocking_limit, idle_limit])).to eq(49.0)

    bucket_keys = bucket_keys_for(limiter)
    expect(bucket_keys).to include(["global", 60.0])
    expect(bucket_keys).not_to include(["tenant-1", 10.0])
  end

  it "evicts idle one-shot buckets when unrelated traffic continues" do
    idle_limit = { limit: 1, interval: 10.0, key: "tenant-1" }
    active_limit = { limit: 2, interval: 60.0, key: "global" }
    limiter.wait_time_for([idle_limit])
    allow(clock).to receive(:call).and_return(1011.0)

    expect(limiter.wait_time_for([active_limit])).to eq(0.0)

    bucket_keys = bucket_keys_for(limiter)
    expect(bucket_keys).to include(["global", 60.0])
    expect(bucket_keys).not_to include(["tenant-1", 10.0])
  end

  it "requires rate limit keys" do
    expect { limiter.wait_time_for([{ limit: 1, interval: 1.0 }]) }
      .to raise_error(ArgumentError, /key must be present/)
  end

  def bucket_keys_for(limiter)
    limiter
      .instance_variable_get(:@bucket_store)
      .instance_variable_get(:@buckets_by_key)
      .keys
  end
end
