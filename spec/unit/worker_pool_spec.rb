# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/worker_runtime"

module WorkerPoolSpecSupport
  FakeFork = Struct.new(:pid, :environment, :command, keyword_init: true)
  FakeStatus = Struct.new(:success?, keyword_init: true)

  class FakeProcessAdapter
    attr_accessor :on_fork, :on_sleep, :on_wait_nonblock
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
      @on_fork&.call(@next_pid)
      @next_pid
    end

    def kill(signal, pid)
      @signals << [signal, pid]
    end

    def wait_nonblock(pid)
      @on_wait_nonblock&.call(pid)
      pid
    end

    def wait(pid_or_pids)
      @waits << pid_or_pids
      raise Errno::ECHILD
    end

    def sleep(duration)
      @sleeps << duration
      @on_sleep&.call(duration)
    end

    def fork_supported? = true
  end
end

describe ActiveJob::Temporal::WorkerPool do
  let(:process_adapter) { WorkerPoolSpecSupport::FakeProcessAdapter.new }
  let(:worker_command) { ["temporal-worker"] }

  before do
    @logger_events = call_recorded_method(ActiveJob::Temporal::Logger, :log_event)
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

    assert_equal [1001, 1002, 1003], process_adapter.forks.map(&:pid)
    assert(process_adapter.forks.all? { |fork| fork.command == worker_command })

    worker_indexes = process_adapter.forks.map { |fork| fork.environment["ACTIVEJOB_TEMPORAL_WORKER_POOL_INDEX"] }
    assert_equal %w[0 1 2], worker_indexes
  ensure
    pool&.stop
  end

  it "uses the bundled worker executable by default" do
    command = described_class.default_worker_command

    assert_equal RbConfig.ruby, command.first
    assert command.last.end_with?("/bin/temporal-worker")
    assert File.exist?(command.last)
  end

  it "assigns per-worker health and metrics ports from base ports" do
    pool = build_pool(
      size: 3,
      health_check_bind: "0.0.0.0",
      health_check_allow_public_bind: true,
      health_check_port: 8080,
      metrics_bind: "0.0.0.0",
      metrics_allow_public_bind: true,
      metrics_port: 9394,
      max_concurrent_activities: 200,
      max_concurrent_workflows: 25
    )

    pool.start(supervise: false)

    health_check_ports = process_adapter.forks.map { |fork| fork.environment["ACTIVEJOB_TEMPORAL_HEALTH_CHECK_PORT"] }
    metrics_ports = process_adapter.forks.map { |fork| fork.environment["ACTIVEJOB_TEMPORAL_METRICS_PORT"] }

    assert_equal %w[8080 8081 8082], health_check_ports
    assert_equal %w[9394 9395 9396], metrics_ports
    expected_environment = {
      "ACTIVEJOB_TEMPORAL_HEALTH_CHECK_BIND" => "0.0.0.0",
      "ACTIVEJOB_TEMPORAL_HEALTH_CHECK_ALLOW_PUBLIC_BIND" => "true",
      "ACTIVEJOB_TEMPORAL_METRICS_BIND" => "0.0.0.0",
      "ACTIVEJOB_TEMPORAL_METRICS_ALLOW_PUBLIC_BIND" => "true",
      "ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES" => "200",
      "ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS" => "25",
      "ACTIVEJOB_TEMPORAL_WORKER_POOL_SIZE" => "1"
    }
    assert_hash_includes expected_environment, process_adapter.forks.first.environment
  ensure
    pool&.stop
  end

  it "restarts a worker that exits while the pool is running" do
    pool = build_pool(size: 1)
    pool.start(supervise: false)

    pool.__send__(:handle_worker_exit, 1001, WorkerPoolSpecSupport::FakeStatus.new(success?: false))

    assert_equal [1001, 1002], process_adapter.forks.map(&:pid)
    assert_equal "0", process_adapter.forks.last.environment["ACTIVEJOB_TEMPORAL_WORKER_POOL_INDEX"]
  ensure
    pool&.stop
  end

  it "caps the restart count carried across chronic crash loops" do
    stub_const("ActiveJob::Temporal::WorkerPool::MAX_RESTART_COUNT", 2)
    pool = build_pool(size: 1)
    pool.start(supervise: false)

    4.times do |offset|
      pool.__send__(:handle_worker_exit, 1001 + offset, WorkerPoolSpecSupport::FakeStatus.new(success?: false))
    end

    started_with_capped_restarts = @logger_events.calls_for(:log_event).count do |call|
      attributes = call.arguments[1] || call.keywords

      call.arguments.first == "worker_pool_worker_started" &&
        attributes[:worker_index] == 0 &&
        attributes[:restarts] == 2
    end
    assert_equal 3, started_with_capped_restarts
  ensure
    pool&.stop
  end

  it "does not restart workers during shutdown" do
    pool = build_pool(size: 1)
    pool.start(supervise: false)
    pool.stop

    pool.__send__(:handle_worker_exit, 1001, WorkerPoolSpecSupport::FakeStatus.new(success?: false))

    assert_equal [1001], process_adapter.forks.map(&:pid)
  end

  it "does not restart a worker when shutdown begins during the restart delay" do
    pool = build_pool(size: 1, restart_delay: 0.1)
    pool.start(supervise: false)
    process_adapter.on_sleep = lambda do |_duration|
      process_adapter.on_sleep = nil
      pool.stop
    end

    pool.__send__(:handle_worker_exit, 1001, WorkerPoolSpecSupport::FakeStatus.new(success?: false))

    assert_equal [1001], process_adapter.forks.map(&:pid)
  end

  it "terminates a restarted worker when shutdown begins before registration" do
    pool = build_pool(size: 1)
    process_adapter.on_fork = ->(pid) { pool.stop if pid == 1002 }
    pool.start(supervise: false)

    pool.__send__(:handle_worker_exit, 1001, WorkerPoolSpecSupport::FakeStatus.new(success?: false))

    assert_equal [1001, 1002], process_adapter.forks.map(&:pid)
    assert_equal [["TERM", 1002]], process_adapter.signals
    assert_equal 0, pool.__send__(:child_count)
  end

  it "stops only once when stop is called concurrently" do
    pool = build_pool(size: 1)
    first_wait_started = Queue.new
    release_first_wait = Queue.new
    wait_calls = 0
    pool.start(supervise: false)
    process_adapter.on_wait_nonblock = lambda do |_pid|
      wait_calls += 1
      next unless wait_calls == 1

      first_wait_started << true
      release_first_wait.pop
    end
    stop_thread = Thread.new { pool.stop }

    first_wait_started.pop
    pool.stop
    release_first_wait << true
    stop_thread.join

    assert_equal [["TERM", 1001]], process_adapter.signals
  end

  it "sends TERM to child workers when stopped" do
    pool = build_pool(size: 2)
    pool.start(supervise: false)

    pool.stop

    assert_unordered_equal [["TERM", 1001], ["TERM", 1002]], process_adapter.signals
  end

  it "waits only on child workers managed by the pool" do
    pool = build_pool(size: 2)
    pool.start(supervise: false)
    call_recorded_method(pool, :running?, returns: false)

    pool.__send__(:supervise_workers)

    assert_equal [1001, 1002], process_adapter.waits.first
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

    assert_equal pool_child, waited_pid
    assert_equal unrelated_child, Process.wait(unrelated_child)
  ensure
    [pool_child, unrelated_child].compact.each do |pid|
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end
  end

  it "rejects invalid pool sizes" do
    error = assert_raises(ArgumentError) { build_pool(size: 0) }

    assert_match(/pool size must be a positive integer/, error.message)
  end

  it "rejects public health binds without explicit opt-in" do
    error = assert_raises(ArgumentError) do
      build_pool(health_check_port: 8080, health_check_bind: "0.0.0.0")
    end

    assert_match(/health check endpoint.*public bind opt-in/, error.message)
  end

  it "rejects public metrics binds without explicit opt-in" do
    error = assert_raises(ArgumentError) do
      build_pool(metrics_port: 9394, metrics_bind: "0.0.0.0")
    end

    assert_match(/metrics endpoint.*public bind opt-in/, error.message)
  end
end
