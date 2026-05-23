# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
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

  it "rejects an explicit missing RAILS_ROOT before connecting to Temporal" do
    Dir.mktmpdir do |directory|
      missing_root = File.join(directory, "missing")

      _stdout, stderr, status = capture_worker("RAILS_ROOT" => missing_root)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("Cannot find Rails application at: #{missing_root}")
    end
  end

  it "warns for an explicit non-Rails RAILS_ROOT and continues" do
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = capture_worker(
        "RAILS_ROOT" => directory,
        "ACTIVEJOB_TEMPORAL_WORKER_POOL_SIZE" => "0"
      )

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("#{directory} does not appear to be a Rails application")
      expect(stderr).to include("--pool-size must be a positive integer")
    end
  end

  it "rejects a Rails root missing config/environment.rb before connecting to Temporal" do
    Dir.mktmpdir do |directory|
      config_path = File.join(directory, "config")
      Dir.mkdir(config_path)
      File.write(File.join(config_path, "application.rb"), "# application\n")

      _stdout, stderr, status = capture_worker("RAILS_ROOT" => directory)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("Cannot find Rails environment")
    end
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
