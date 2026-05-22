# frozen_string_literal: true

module ActiveJob
  module Temporal
    module HttpLineReader
      private

      def read_line(client)
        deadline = monotonic_time + self.class.const_get(:READ_TIMEOUT_SECONDS)
        buffer = +""

        loop do
          remaining = deadline - monotonic_time
          return if remaining <= 0 || !client.wait_readable(remaining)

          chunk = client.read_nonblock(1, exception: false)
          case chunk
          when :wait_readable
            next
          when nil
            return buffer unless buffer.empty?

            return
          else
            buffer << chunk
            return buffer if chunk == "\n"
          end
        end
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
