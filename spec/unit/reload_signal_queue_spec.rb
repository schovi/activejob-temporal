# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe ActiveJob::Temporal::ReloadSignalQueue do
  subject(:queue) { described_class.new }

  it "coalesces repeated reload signals while one is pending" do
    expect(queue.push("HUP")).to eq("HUP")
    expect(queue.push("HUP")).to be_nil

    expect(queue.pop).to eq("HUP")
  end

  it "allows one signal to wait while a reload is running" do
    queue.push("HUP")
    expect(queue.pop).to eq("HUP")

    expect(queue.push("HUP")).to eq("HUP")
    expect(queue.push("HUP")).to be_nil
  end

  it "wakes consumers when closed" do
    consumer = Thread.new { queue.pop }

    queue.close

    expect(consumer.value).to be_nil
  end

  it "drops pending reload work when closed" do
    queue.push("HUP")
    queue.close

    expect(queue.pop).to be_nil
  end

  it "drops signals after close" do
    queue.close

    expect(queue.push("HUP")).to be_nil
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

    expect(status).to be_success
    expect(stdout).to eq("USR2\n")
  end
end
