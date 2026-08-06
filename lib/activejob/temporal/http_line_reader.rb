# frozen_string_literal: true

module ActiveJob
  module Temporal
    # Bounded line reading for the embedded HTTP endpoints: one deadline for the
    # whole request plus caps on line length and header count, so a slow or
    # oversized client cannot hold a connection worker.
    module HttpLineReader
      MAX_LINE_BYTES = 8_192
      MAX_HEADER_LINES = 100

      private

      # @return [Float] monotonic deadline covering an entire request
      def request_deadline
        monotonic_time + self.class.const_get(:READ_TIMEOUT_SECONDS)
      end

      def read_line(client, deadline)
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
            return if buffer.bytesize >= MAX_LINE_BYTES
          end
        end
      end

      def drain_headers(client, deadline)
        MAX_HEADER_LINES.times do
          line = read_line(client, deadline)
          break if line.nil? || line == "\r\n" || line == "\n"
        end
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
