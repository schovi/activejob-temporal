# frozen_string_literal: true

module ActiveJob
  module Temporal
    # Single-slot signal handoff between a trap handler and the reload thread.
    #
    # Backed by Thread::Queue because trap context forbids taking a Mutex.
    class ReloadSignalQueue
      def initialize
        @queue = Thread::Queue.new
      end

      # Enqueues a reload signal unless one is already pending or the queue is closed.
      #
      # @param signal [String] Signal name
      # @return [String, nil] The signal when enqueued, nil when coalesced or closed
      def push(signal)
        return nil if @queue.closed? || !@queue.empty?

        @queue << signal
        signal
      rescue ClosedQueueError
        nil
      end

      # Blocks until a signal is pending or the queue is closed.
      #
      # @return [String, nil] The pending signal, or nil once closed
      def pop
        @queue.pop
      end

      # @return [void]
      def close
        @queue.clear
        @queue.close
      end
    end
  end
end
