# frozen_string_literal: true

module ActiveJob
  module Temporal
    class ReloadSignalQueue
      POLL_INTERVAL_SECONDS = 0.05

      def initialize
        @pending_signal = nil
        @closed = false
      end

      def push(signal)
        return if @closed || @pending_signal

        @pending_signal = signal
        signal
      end

      def pop
        loop do
          return nil if @closed

          if @pending_signal
            signal = @pending_signal
            @pending_signal = nil
            return signal
          end

          sleep(POLL_INTERVAL_SECONDS)
        end
      end

      def close
        @closed = true
        @pending_signal = nil
      end
    end
  end
end
