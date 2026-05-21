# frozen_string_literal: true

require "spec_helper"

module WorkerPoolSpecSupport
  FakeFork = Struct.new(:pid, :environment, :command, keyword_init: true)
  FakeStatus = Struct.new(:success?, keyword_init: true)

  class FakeProcessAdapter
    attr_reader :forks, :signals, :sleeps, :waits

    def initialize
      @forks = []
      @signals = []
      @sleeps = []
      @waits = []
      @next_pid = 1000
    end

    def fork(environment, command)
      @next_pid += 1
      @forks << FakeFork.new(pid: @next_pid, environment: environment, command: command)
      @next_pid
    end

    def kill(signal, pid)
      @signals << [signal, pid]
    end

    def wait_nonblock(pid)
      pid
    end

    def wait(pid_or_pids)
      @waits << pid_or_pids
      raise Errno::ECHILD
    end

    def sleep(duration)
      @sleeps << duration
    end

    def fork_supported? = true
  end
end

RSpec.describe ActiveJob::Temporal::WorkerPool do
  let(:process_adapter) { WorkerPoolSpecSupport::FakeProcessAdapter.new }
  let(:worker_command) { ["temporal-worker"] }

  before do
    allow(ActiveJob::Temporal::Logger).to receive(:log_event)
  end

  def build_pool(**options)
    described_class.new(
      size: options.fetch(:size, 2),
      worker_command: worker_command,
      process_adapter: process_adapter,
      install_signal_handlers: false,
      restart_delay: 0,
      **options.except(:size)
    )
  end

  it "spawns the configured number of worker processes" do
    pool = build_pool(size: 3)

    pool.start(supervise: false)

    expect(process_adapter.forks.map(&:pid)).to eq([1001, 1002, 1003])
    expect(process_adapter.forks.map(&:command)).to all(eq(worker_command))
    expect(process_adapter.forks.map { |fork| fork.environment["ACTIVEJOB_TEMPORAL_WORKER_POOL_INDEX"] })
      .to eq(%w[0 1 2])
  ensure
    pool&.stop
  end

  it "uses the bundled worker executable by default" do
    command = described_class.default_worker_command

    expect(command.first).to eq(RbConfig.ruby)
    expect(command.last).to end_with("/bin/temporal-worker")
    expect(File).to exist(command.last)
  end

  it "assigns per-worker health and metrics ports from base ports" do
    pool = build_pool(
      size: 3,
      health_check_bind: "0.0.0.0",
      health_check_port: 8080,
      metrics_bind: "0.0.0.0",
      metrics_port: 9394,
      max_concurrent_activities: 200,
      max_concurrent_workflows: 25
    )

    pool.start(supervise: false)

    expect(process_adapter.forks.map { |fork| fork.environment["ACTIVEJOB_TEMPORAL_HEALTH_CHECK_PORT"] })
      .to eq(%w[8080 8081 8082])
    expect(process_adapter.forks.map { |fork| fork.environment["ACTIVEJOB_TEMPORAL_METRICS_PORT"] })
      .to eq(%w[9394 9395 9396])
    expect(process_adapter.forks.first.environment).to include(
      "ACTIVEJOB_TEMPORAL_HEALTH_CHECK_BIND" => "0.0.0.0",
      "ACTIVEJOB_TEMPORAL_METRICS_BIND" => "0.0.0.0",
      "ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES" => "200",
      "ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS" => "25",
      "ACTIVEJOB_TEMPORAL_WORKER_POOL_SIZE" => "1"
    )
  ensure
    pool&.stop
  end

  it "restarts a worker that exits while the pool is running" do
    pool = build_pool(size: 1)
    pool.start(supervise: false)

    pool.__send__(:handle_worker_exit, 1001, WorkerPoolSpecSupport::FakeStatus.new(success?: false))

    expect(process_adapter.forks.map(&:pid)).to eq([1001, 1002])
    expect(process_adapter.forks.last.environment["ACTIVEJOB_TEMPORAL_WORKER_POOL_INDEX"]).to eq("0")
  ensure
    pool&.stop
  end

  it "does not restart workers during shutdown" do
    pool = build_pool(size: 1)
    pool.start(supervise: false)
    pool.stop

    pool.__send__(:handle_worker_exit, 1001, WorkerPoolSpecSupport::FakeStatus.new(success?: false))

    expect(process_adapter.forks.map(&:pid)).to eq([1001])
  end

  it "sends TERM to child workers when stopped" do
    pool = build_pool(size: 2)
    pool.start(supervise: false)

    pool.stop

    expect(process_adapter.signals).to contain_exactly(["TERM", 1001], ["TERM", 1002])
  end

  it "waits only on child workers managed by the pool" do
    pool = build_pool(size: 2)
    pool.start(supervise: false)
    allow(pool).to receive(:running?).and_return(false)

    pool.__send__(:supervise_workers)

    expect(process_adapter.waits.first).to eq([1001, 1002])
  ensure
    pool&.stop
  end

  it "does not reap unrelated child processes when waiting for pool workers" do
    adapter = described_class::ProcessAdapter.new
    pool_child = Process.fork { exit!(0) }
    unrelated_child = Process.fork do
      sleep 0.2
      exit!(0)
    end

    waited_pid, = adapter.wait([pool_child])

    expect(waited_pid).to eq(pool_child)
    expect(Process.wait(unrelated_child)).to eq(unrelated_child)
  ensure
    [pool_child, unrelated_child].compact.each do |pid|
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end
  end

  it "rejects invalid pool sizes" do
    expect { build_pool(size: 0) }
      .to raise_error(ArgumentError, /pool size must be a positive integer/)
  end
end
