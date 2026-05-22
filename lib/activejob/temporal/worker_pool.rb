# frozen_string_literal: true

require "rbconfig"

module ActiveJob
  module Temporal
    # rubocop:disable Metrics/ClassLength
    class WorkerPool
      Child = Data.define(:pid, :index, :restarts)

      DEFAULT_RESTART_DELAY = 1.0
      DEFAULT_SHUTDOWN_TIMEOUT = 10.0
      SHUTDOWN_SIGNALS = %w[INT TERM].freeze
      VALID_OPTIONS = %i[
        worker_command
        process_adapter
        health_check_port
        health_check_bind
        metrics_port
        metrics_bind
        max_concurrent_activities
        max_concurrent_workflows
        restart_delay
        shutdown_timeout
        install_signal_handlers
      ].freeze

      def initialize(size:, **options)
        validate_options!(options)

        @size = positive_integer(size, "pool size")
        configure_process_options(options)
        configure_runtime_options(options)
        initialize_state
        validate!
      end

      def self.default_worker_command
        bundled_executable = File.expand_path("../../../bin/temporal-worker", __dir__)
        return [RbConfig.ruby, bundled_executable] if File.exist?(bundled_executable)

        ["temporal-worker"]
      end

      def start(supervise: true)
        ensure_fork_supported!

        @mutex.synchronize do
          return self if @running

          @running = true
          @stopping = false
        end

        install_signal_handlers if @install_signal_handlers
        @size.times { |index| start_worker(index) }
        @supervisor_thread = Thread.new { supervise_workers } if supervise
        self
      end

      def wait
        @supervisor_thread&.join
        self
      end

      def stop
        children = @mutex.synchronize do
          if @stopping
            nil
          else
            @stopping = true
            @running = false

            @children.values
          end
        end
        return self unless children

        children.each { |child| terminate_worker(child) }
        deadline = monotonic_time + @shutdown_timeout
        children.each { |child| wait_for_worker(child, deadline) }
        @mutex.synchronize { children.each { |child| @children.delete(child.pid) } }
        restore_signal_handlers if @install_signal_handlers
        self
      end

      def running?
        @mutex.synchronize { @running }
      end

      private

      def validate_options!(options)
        unknown_options = options.keys - VALID_OPTIONS
        return if unknown_options.empty?

        raise ArgumentError, "unknown worker pool options: #{unknown_options.join(', ')}"
      end

      def configure_process_options(options)
        worker_command = options.fetch(:worker_command, nil)
        @worker_command = Array(worker_command || self.class.default_worker_command)
        @process_adapter = options.fetch(:process_adapter) { ProcessAdapter.new }
      end

      def configure_runtime_options(options)
        @health_check_port = optional_positive_integer(options.fetch(:health_check_port, nil), "health_check_port")
        @health_check_bind = options.fetch(:health_check_bind, nil)
        @metrics_port = optional_positive_integer(options.fetch(:metrics_port, nil), "metrics_port")
        @metrics_bind = options.fetch(:metrics_bind, nil)
        @max_concurrent_activities =
          optional_positive_integer(options.fetch(:max_concurrent_activities, nil), "max_concurrent_activities")
        @max_concurrent_workflows =
          optional_positive_integer(options.fetch(:max_concurrent_workflows, nil), "max_concurrent_workflows")
        @restart_delay = Float(options.fetch(:restart_delay, DEFAULT_RESTART_DELAY))
        @shutdown_timeout = Float(options.fetch(:shutdown_timeout, DEFAULT_SHUTDOWN_TIMEOUT))
        @install_signal_handlers = options.fetch(:install_signal_handlers, true)
      end

      def initialize_state
        @children = {}
        @mutex = Mutex.new
        @running = false
        @stopping = false
        @previous_signal_handlers = {}
      end

      def validate!
        raise ArgumentError, "worker_command must not be empty" if @worker_command.empty?
        raise ArgumentError, "restart_delay must be finite and non-negative" unless finite_non_negative?(@restart_delay)
        return if finite_non_negative?(@shutdown_timeout)

        raise ArgumentError, "shutdown_timeout must be finite and non-negative"
      end

      def positive_integer(value, name)
        integer = Integer(value)
        return integer if integer.positive?

        raise ArgumentError, "#{name} must be a positive integer"
      rescue TypeError, ArgumentError
        raise ArgumentError, "#{name} must be a positive integer"
      end

      def optional_positive_integer(value, name)
        return if value.nil?

        positive_integer(value, name)
      end

      def finite_non_negative?(value)
        value.finite? && !value.negative?
      end

      def ensure_fork_supported!
        return if @process_adapter.fork_supported?

        raise ActiveJob::Temporal::ConfigurationError, "worker pools require Process.fork support"
      end

      def start_worker(index, restarts: 0)
        environment = worker_environment(index)
        pid = @process_adapter.fork(environment, @worker_command)
        child = Child.new(pid: pid, index: index, restarts: restarts)

        unless register_worker_if_running(child)
          terminate_worker(child)
          wait_for_worker(child, monotonic_time + @shutdown_timeout)
          return
        end

        ActiveJob::Temporal::Logger.log_event(
          "worker_pool_worker_started",
          worker_index: index,
          pid: pid,
          restarts: restarts
        )
      end

      def register_worker_if_running(child)
        @mutex.synchronize do
          if @stopping || !@running
            false
          else
            @children[child.pid] = child

            true
          end
        end
      end

      def worker_environment(index)
        environment = {
          "ACTIVEJOB_TEMPORAL_WORKER_POOL_INDEX" => index.to_s,
          "ACTIVEJOB_TEMPORAL_WORKER_POOL_SIZE" => "1"
        }

        environment["ACTIVEJOB_TEMPORAL_HEALTH_CHECK_PORT"] = (@health_check_port + index).to_s if @health_check_port
        environment["ACTIVEJOB_TEMPORAL_HEALTH_CHECK_BIND"] = @health_check_bind.to_s if @health_check_bind
        environment["ACTIVEJOB_TEMPORAL_METRICS_PORT"] = (@metrics_port + index).to_s if @metrics_port
        environment["ACTIVEJOB_TEMPORAL_METRICS_BIND"] = @metrics_bind.to_s if @metrics_bind
        if @max_concurrent_activities
          environment["ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES"] = @max_concurrent_activities.to_s
        end
        if @max_concurrent_workflows
          environment["ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS"] = @max_concurrent_workflows.to_s
        end

        environment
      end

      def supervise_workers
        loop do
          pid, status = @process_adapter.wait(worker_pids)
          handle_worker_exit(pid, status)
          break unless running? || child_count.positive?
        rescue Errno::ECHILD
          break unless running?

          @process_adapter.sleep(0.1)
        end
      ensure
        stop if running?
      end

      def handle_worker_exit(pid, status)
        child = @mutex.synchronize { @children.delete(pid) }
        return unless child

        ActiveJob::Temporal::Logger.log_event(
          "worker_pool_worker_exited",
          worker_index: child.index,
          pid: pid,
          success: status.respond_to?(:success?) ? status.success? : nil
        )

        return unless restart_allowed?

        @process_adapter.sleep(@restart_delay) if @restart_delay.positive?
        return unless restart_allowed?

        start_worker(child.index, restarts: child.restarts + 1)
      end

      def child_count
        @mutex.synchronize { @children.size }
      end

      def worker_pids
        @mutex.synchronize { @children.keys }
      end

      def restart_allowed?
        @mutex.synchronize { @running && !@stopping }
      end

      def terminate_worker(child)
        @process_adapter.kill("TERM", child.pid)
      rescue Errno::ESRCH
        nil
      end

      def wait_for_worker(child, deadline)
        loop do
          return if @process_adapter.wait_nonblock(child.pid)

          break if monotonic_time >= deadline

          @process_adapter.sleep(0.1)
        end

        @process_adapter.kill("KILL", child.pid)
        @process_adapter.wait(child.pid)
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end

      def install_signal_handlers
        @mutex.synchronize do
          signal_queue = Queue.new
          @signal_queue = signal_queue
          SHUTDOWN_SIGNALS.each do |signal|
            @previous_signal_handlers[signal] = Signal.trap(signal) { signal_queue << signal }
          end
          @signal_thread = Thread.new do
            signal = signal_queue.pop
            unless signal == :shutdown
              ActiveJob::Temporal::Logger.log_event("worker_pool_shutdown_requested", signal: signal)
              stop
            end
          end
        end
      end

      def restore_signal_handlers
        previous_signal_handlers, signal_queue, signal_thread = @mutex.synchronize do
          [
            @previous_signal_handlers.dup,
            @signal_queue,
            @signal_thread
          ].tap do
            @previous_signal_handlers.clear
            @signal_queue = nil
            @signal_thread = nil
          end
        end

        previous_signal_handlers.each do |signal, handler|
          Signal.trap(signal, handler)
        end
        signal_queue << :shutdown if signal_queue && !signal_queue.closed?
        signal_thread&.join(1) if signal_thread&.alive? && signal_thread != Thread.current
      rescue ArgumentError
        nil
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      class ProcessAdapter
        def fork(environment, command)
          Process.fork do
            environment.each { |key, value| ENV[key] = value }
            exec(*command)
          end
        end

        def wait(pids)
          if pids.is_a?(Integer)
            Process.wait2(pids)
          else
            wait_for_any(pids)
          end
        end

        def wait_nonblock(pid)
          Process.wait(pid, Process::WNOHANG)
        end

        def kill(signal, pid)
          Process.kill(signal, pid)
        end

        def sleep(duration)
          Kernel.sleep(duration)
        end

        def fork_supported?
          Process.respond_to?(:fork)
        end

        private

        def wait_for_any(pids)
          raise Errno::ECHILD if pids.empty?

          loop do
            pids.each do |pid|
              waited_pid, status = Process.wait2(pid, Process::WNOHANG)
              return [waited_pid, status] if waited_pid
            rescue Errno::ECHILD
              return [pid, nil]
            end

            sleep(0.1)
          end
        end
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
