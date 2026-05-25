# frozen_string_literal: true

module ActiveJob
  module Temporal
    class ConnectionWorkerPool
      def initialize(size:, queue_size:, name:, &handler)
        @size = Integer(size)
        @queue_size = Integer(queue_size)
        @name = name
        @handler = handler
        @mutex = Mutex.new
        @started = false

        raise ArgumentError, "size must be positive" unless @size.positive?
        raise ArgumentError, "queue_size must be positive" unless @queue_size.positive?
        raise ArgumentError, "handler is required" unless @handler
      end

      def start
        @mutex.synchronize do
          return self if @started

          @queue = SizedQueue.new(@queue_size)
          queue = @queue
          @workers = Array.new(@size) do |index|
            Thread.new(queue, index) { |worker_queue, worker_index| run_worker(worker_queue, worker_index) }
          end
          @started = true
        end

        self
      end

      def enqueue(connection)
        queue = @mutex.synchronize { @queue if @started }
        unless queue
          close_connection(connection)
          return false
        end

        queue.push(connection, true)
        true
      rescue ClosedQueueError, ThreadError
        close_connection(connection)
        false
      end

      def stop(timeout:)
        queue = nil
        workers = nil

        @mutex.synchronize do
          return unless @started

          queue = @queue
          workers = @workers
          @queue = nil
          @workers = []
          @started = false
        end

        queue.close
        workers.each { |worker| worker.join(timeout) }
      end

      private

      def run_worker(queue, index)
        Thread.current.name = "#{@name}-#{index}" if Thread.current.respond_to?(:name=)

        loop do
          connection = queue.pop
          break unless connection

          begin
            @handler.call(connection)
          rescue StandardError => e
            log_handler_failure(index, e)
            close_connection(connection)
          end
        end
      rescue ClosedQueueError
        nil
      end

      def log_handler_failure(index, error)
        ActiveJob::Temporal::Logger.error(
          "connection_worker_handler_failed",
          pool: @name,
          worker_index: index,
          error_class: error.class.name,
          message: error.message.to_s
        )
      rescue StandardError
        nil
      end

      def close_connection(connection)
        connection.close
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
