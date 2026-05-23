# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "timeout"

RSpec.describe "temporal-worker CLI" do
  it "rejects invalid worker pool sizes before connecting to Temporal" do
    _stdout, stderr, status = capture_worker("ACTIVEJOB_TEMPORAL_WORKER_POOL_SIZE" => "0")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("--pool-size must be a positive integer")
  end

  it "rejects reserved TLS reload signals before connecting to Temporal" do
    _stdout, stderr, status = capture_worker(
      "ACTIVEJOB_TEMPORAL_TLS_RELOAD_SIGNAL" => "TERM"
    )

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("ACTIVEJOB_TEMPORAL_TLS_RELOAD_SIGNAL must be a signal name safe to trap")
  end

  it "rejects public health binds without explicit opt-in before connecting to Temporal" do
    _stdout, stderr, status = capture_worker(
      "ACTIVEJOB_TEMPORAL_HEALTH_CHECK_PORT" => "8080",
      "ACTIVEJOB_TEMPORAL_HEALTH_CHECK_BIND" => "0.0.0.0"
    )

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("health check endpoint")
    expect(stderr).to include("--allow-public-health-check-bind")
  end

  it "rejects public metrics binds without explicit opt-in before connecting to Temporal" do
    _stdout, stderr, status = capture_worker(
      "ACTIVEJOB_TEMPORAL_METRICS_PORT" => "9394",
      "ACTIVEJOB_TEMPORAL_METRICS_BIND" => "0.0.0.0"
    )

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("metrics endpoint")
    expect(stderr).to include("--allow-public-metrics-bind")
  end

  def capture_worker(env)
    Timeout.timeout(5) do
      Open3.capture3(
        env,
        RbConfig.ruby,
        "-rbundler/setup",
        "bin/temporal-worker"
      )
    end
  end
end
