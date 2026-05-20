# frozen_string_literal: true

require "spec_helper"
require "json"
require "socket"
require "timeout"

RSpec.describe ActiveJob::Temporal::HealthCheckServer do
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

      expect(@server.bind_address).to eq("127.0.0.1")
    end

    it "serves worker health as JSON" do
      state.mark_started!
      state.record_task_started!(now: Time.utc(2026, 5, 20, 10, 1, 0))
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start

      response = http_request("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      status, body = parse_response(response)

      expect(status).to eq("HTTP/1.1 200 OK")
      expect(body["status"]).to eq("ok")
      expect(body["worker_running"]).to be(true)
      expect(body["task_queue"]).to eq("critical")
      expect(body["max_concurrent_activities"]).to eq(50)
      expect(body["active_tasks"]).to eq(1)
      expect(body["last_poll"]).to eq("2026-05-20T10:01:00Z")
    end

    it "returns service unavailable when the worker is stopped" do
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start

      response = http_request("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      status, body = parse_response(response)

      expect(status).to eq("HTTP/1.1 503 Service Unavailable")
      expect(body["status"]).to eq("stopped")
    end

    it "returns not found for other paths" do
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start

      response = http_request("GET /missing HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      status, body = parse_response(response)

      expect(status).to eq("HTTP/1.1 404 Not Found")
      expect(body["error"]).to eq("not_found")
    end

    it "returns no response body for HEAD requests" do
      state.mark_started!
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start

      response = http_request("HEAD /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      headers, body = response.split("\r\n\r\n", 2)

      expect(headers).to include("HTTP/1.1 200 OK")
      expect(headers).to include("Content-Length: 0")
      expect(body.to_s).to eq("")
    end

    it "returns bad request for malformed request lines" do
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start

      response = http_request("GET\r\nHost: 127.0.0.1\r\n\r\n")
      status, body = parse_response(response)

      expect(status).to eq("HTTP/1.1 400 Bad Request")
      expect(body["error"]).to eq("bad_request")
    end

    it "keeps serving when another client stalls mid-request" do
      state.mark_started!
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start
      stalled_socket = TCPSocket.new("127.0.0.1", @server.port)
      stalled_socket.write("GET /health HTTP/1.1\r\n")

      response = http_request("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      status, body = parse_response(response)

      expect(status).to eq("HTTP/1.1 200 OK")
      expect(body["status"]).to eq("ok")
    ensure
      stalled_socket&.close
    end

    it "keeps running when a client disconnects before reading the response" do
      state.mark_started!
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", state: state).start
      socket = TCPSocket.new("127.0.0.1", @server.port)
      socket.write("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      socket.close

      response = http_request("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      status, body = parse_response(response)

      expect(@server.running?).to be(true)
      expect(status).to eq("HTTP/1.1 200 OK")
      expect(body["status"]).to eq("ok")
    end
  end

  private

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
