# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "temporal-worker CLI" do
  it "rejects invalid worker pool sizes before connecting to Temporal" do
    _stdout, stderr, status = Open3.capture3(
      { "ACTIVEJOB_TEMPORAL_WORKER_POOL_SIZE" => "0" },
      RbConfig.ruby,
      "-rbundler/setup",
      "bin/temporal-worker"
    )

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("--pool-size must be a positive integer")
  end
end
