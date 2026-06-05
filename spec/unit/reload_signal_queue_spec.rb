# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "activejob/temporal/worker_runtime"

describe ActiveJob::Temporal::ReloadSignalQueue do
  let(:queue) { described_class.new }

  it "coalesces repeated reload signals while one is pending" do
    assert_equal "HUP", queue.push("HUP")
    assert_nil queue.push("HUP")

    assert_equal "HUP", queue.pop
  end

  it "allows one signal to wait while a reload is running" do
    queue.push("HUP")
    assert_equal "HUP", queue.pop

    assert_equal "HUP", queue.push("HUP")
    assert_nil queue.push("HUP")
  end

  it "wakes consumers when closed" do
    consumer = Thread.new { queue.pop }

    queue.close

    assert_nil consumer.value
  end

  it "drops pending reload work when closed" do
    queue.push("HUP")
    queue.close

    assert_nil queue.pop
  end

  it "drops signals after close" do
    queue.close

    assert_nil queue.push("HUP")
  end

  it "can be pushed from a signal trap" do
    skip "USR2 is unavailable on this platform" unless Signal.list.key?("USR2")

    stdout, _stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-Ilib",
      "-ractivejob/temporal/reload_signal_queue",
      "-e",
      <<~RUBY
        queue = ActiveJob::Temporal::ReloadSignalQueue.new
        previous_handler = Signal.trap("USR2") { queue.push("USR2") }
        Process.kill("USR2", Process.pid)
        puts queue.pop
        Signal.trap("USR2", previous_handler)
      RUBY
    )

    assert status.success?
    assert_equal "USR2\n", stdout
  end
end
