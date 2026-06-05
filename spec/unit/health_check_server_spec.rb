# frozen_string_literal: true

require "spec_helper"
require "json"
require "socket"
require "timeout"
require "activejob/temporal/worker_runtime"

describe ActiveJob::Temporal::HealthCheckServer do
  let(:state) do
    ActiveJob::Temporal::WorkerHealth.new(
      task_queue: "critical",
      namespace: "production",
      target: "temporal.example.com:7233",
      max_concurrent_activities: 50,
      max_concurrent_workflows: 10
    )
  end

  after do
    @server&.stop
  end

  describe "#start" do
    it "defaults to localhost binding" do
      @server = described_class.new(port: 0, state: state).start

      assert_equal "127.0.0.1", @server.bind_address
    end

    it "rejects public binds without explicit opt-in" do
      error = assert_raises(ArgumentError) do
        described_class.new(port: 0, bind_address: "0.0.0.0", state: state).start
      end

      assert_match(/health check endpoint.*public bind opt-in/, error.message)
    end

    it "serves worker health as JSON" do
      state.mark_started!
      state.record_task_started!(now: Time.utc(2026, 5, 20, 10, 1, 0))
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start

      response = http_request("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      status, body = parse_response(response)

      assert_equal "HTTP/1.1 200 OK", status
      assert_equal "ok", body["status"]
      assert_equal true, body["worker_running"]
      assert_equal "critical", body["task_queue"]
      assert_equal 50, body["max_concurrent_activities"]
      assert_equal 1, body["active_tasks"]
      assert_equal "2026-05-20T10:01:00Z", body["last_poll"]
    end

    it "returns service unavailable when the worker is stopped" do
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start

      response = http_request("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      status, body = parse_response(response)

      assert_equal "HTTP/1.1 503 Service Unavailable", status
      assert_equal "stopped", body["status"]
    end

    it "returns not found for other paths" do
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start

      response = http_request("GET /missing HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      status, body = parse_response(response)

      assert_equal "HTTP/1.1 404 Not Found", status
      assert_equal "not_found", body["error"]
    end

    it "returns no response body for HEAD requests" do
      state.mark_started!
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start

      response = http_request("HEAD /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      headers, body = response.split("\r\n\r\n", 2)

      assert_includes headers, "HTTP/1.1 200 OK"
      assert_includes headers, "Content-Length: 0"
      assert_empty body.to_s
    end

    it "returns bad request for malformed request lines" do
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start

      response = http_request("GET\r\nHost: 127.0.0.1\r\n\r\n")
      status, body = parse_response(response)

      assert_equal "HTTP/1.1 400 Bad Request", status
      assert_equal "bad_request", body["error"]
    end

    it "keeps serving when another client stalls mid-request" do
      state.mark_started!
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start
      stalled_socket = TCPSocket.new("127.0.0.1", @server.port)
      stalled_socket.write("GET /health HTTP/1.1\r\n")

      response = http_request("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      status, body = parse_response(response)

      assert_equal "HTTP/1.1 200 OK", status
      assert_equal "ok", body["status"]
    ensure
      stalled_socket&.close
    end

    it "does not create a thread for each stalled client" do
      state.mark_started!
      created_threads = Queue.new
      original_thread_new = Thread.method(:new)
      call_recorded_method(Thread, :new) do |*arguments, &block|
        created_threads << true
        original_thread_new.call(*arguments, &block)
      end
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start
      threads_after_start = created_threads.length

      stalled_sockets = Array.new(5) do
        TCPSocket.new("127.0.0.1", @server.port).tap do |socket|
          socket.write("GET /health HTTP/1.1\r\n")
        end
      end
      sleep 0.2

      assert_equal threads_after_start, created_threads.length
    ensure
      stalled_sockets&.each(&:close)
    end

    it "releases workers held by partial request lines" do
      stub_const("#{described_class.name}::READ_TIMEOUT_SECONDS", 0.1)
      state.mark_started!
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start

      stalled_sockets = Array.new(described_class::CONNECTION_WORKERS) do
        TCPSocket.new("127.0.0.1", @server.port).tap do |socket|
          socket.write("GET /health HTTP/1.1")
        end
      end
      sleep 0.2

      response = http_request("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      status, body = parse_response(response)

      assert_equal "HTTP/1.1 200 OK", status
      assert_equal "ok", body["status"]
    ensure
      stalled_sockets&.each(&:close)
    end

    it "keeps running when a client disconnects before reading the response" do
      state.mark_started!
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start
      socket = TCPSocket.new("127.0.0.1", @server.port)
      socket.write("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      socket.close

      response = http_request("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      status, body = parse_response(response)

      assert @server.running?
      assert_equal "HTTP/1.1 200 OK", status
      assert_equal "ok", body["status"]
    end

    it "returns internal server error for state failures and keeps serving later requests" do
      failing_state = flaky_health_state(described_class::CONNECTION_WORKERS)
      logger_errors = call_recorded_method(ActiveJob::Temporal::Logger, :error)
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: failing_state).start

      described_class::CONNECTION_WORKERS.times do
        status, body = parse_response(http_request("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))

        assert_equal "HTTP/1.1 500 Internal Server Error", status
        assert_equal "internal_server_error", body["error"]
      end

      status, body = parse_response(http_request("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))

      assert_equal "HTTP/1.1 200 OK", status
      assert_equal "ok", body["status"]

      matching_errors = logger_errors.calls_for(:error).count do |call|
        attributes = call.arguments[1] || call.keywords

        call.arguments.first == "health_check_request_failed" &&
          attributes[:error_class] == "RuntimeError" &&
          attributes[:message] == "health snapshot failed"
      end
      assert_equal described_class::CONNECTION_WORKERS, matching_errors
    end
  end

  private

  def flaky_health_state(failures)
    calls = 0
    Object.new.tap do |state|
      state.define_singleton_method(:snapshot) do
        calls += 1
        raise "health snapshot failed" if calls <= failures

        { status: "ok", worker_running: true }
      end
    end
  end

  def http_request(request)
    Timeout.timeout(2) do
      socket = TCPSocket.new("127.0.0.1", @server.port)
      socket.write(request)
      socket.read
    ensure
      socket&.close
    end
  end

  def parse_response(response)
    headers, body = response.split("\r\n\r\n", 2)
    [headers.lines.first.strip, JSON.parse(body)]
  end
end
