# frozen_string_literal: true

require "json"
require "io/wait"
require "socket"

require_relative "connection_worker_pool"
require_relative "http_line_reader"

module ActiveJob
  module Temporal
    class HealthCheckServer
      include HttpLineReader

      DEFAULT_BIND_ADDRESS = "127.0.0.1"
      READ_TIMEOUT_SECONDS = 1
      CONNECTION_WORKERS = 4
      CONNECTION_QUEUE_SIZE = 16

      attr_reader :port, :bind_address

      def initialize(port:, state:, bind_address: DEFAULT_BIND_ADDRESS)
        @requested_port = Integer(port)
        @bind_address = bind_address
        @state = state
        @running = false
        @mutex = Mutex.new
      end

      def start
        @mutex.synchronize do
          return self if @running

          @server = TCPServer.new(bind_address, @requested_port)
          @port = @server.addr[1]
          @connection_pool = ConnectionWorkerPool.new(
            size: CONNECTION_WORKERS,
            queue_size: CONNECTION_QUEUE_SIZE,
            name: "activejob-temporal-health"
          ) { |client| serve_client(client) }.start
          @running = true
          @thread = Thread.new { run }
        end

        self
      end

      def stop
        server = nil
        thread = nil
        connection_pool = nil

        @mutex.synchronize do
          server = @server
          thread = @thread
          connection_pool = @connection_pool
          @server = nil
          @thread = nil
          @connection_pool = nil
          @running = false
        end

        server&.close
        connection_pool&.stop(timeout: 2)
        thread&.join(2)
      end

      def running?
        @mutex.synchronize { @running }
      end

      private

      def run
        loop do
          server, connection_pool = @mutex.synchronize { [@server, @connection_pool] }
          break unless server && connection_pool

          connection_pool.enqueue(server.accept)
        rescue IOError, Errno::EBADF
          break
        end
      ensure
        @mutex.synchronize { @running = false if @server }
      end

      def serve_client(client)
        handle_client(client)
      rescue IOError, SystemCallError
        nil
      ensure
        client&.close
      end

      def handle_client(client)
        request_line = read_line(client)
        return unless request_line

        method, path = request_line.split.first(2)
        drain_headers(client)

        unless method && path
          write_json(client, 400, { error: "bad_request" })
          return
        end

        case [method, path]
        in ["GET" | "HEAD", "/health"]
          payload = health_payload
          write_json(client, health_status(payload), payload, body: method == "GET")
        in [_, "/health"]
          write_json(client, 405, { error: "method_not_allowed" })
        else
          write_json(client, 404, { error: "not_found" })
        end
      end

      def health_payload
        @state.respond_to?(:snapshot) ? @state.snapshot : @state.call
      end

      def health_status(payload)
        payload[:worker_running] ? 200 : 503
      end

      def drain_headers(client)
        loop do
          line = read_line(client)
          break if line.nil? || line == "\r\n" || line == "\n"
        end
      end

      def write_json(client, status, payload, body: true)
        json = JSON.generate(payload)
        response = "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n"
        response << "Content-Type: application/json\r\n"
        response << "Content-Length: #{body ? json.bytesize : 0}\r\n"
        response << "Connection: close\r\n\r\n"
        response << json if body
        client.write(response)
      end

      def reason_phrase(status)
        {
          200 => "OK",
          400 => "Bad Request",
          404 => "Not Found",
          405 => "Method Not Allowed",
          503 => "Service Unavailable"
        }.fetch(status)
      end
    end
  end
end
