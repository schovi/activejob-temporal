# frozen_string_literal: true

require "spec_helper"
require "socket"
require "timeout"

RSpec.describe ActiveJob::Temporal::MetricsServer do
  let(:provider) do
    double(
      "PrometheusProvider",
      render: "# TYPE activejob_temporal_active_workers gauge\nactivejob_temporal_active_workers 1.0\n"
    )
  end

  after do
    @server&.stop
  end

  describe "#start" do
    it "defaults to localhost binding" do
      @server = described_class.new(port: 0, provider: provider).start

      expect(@server.bind_address).to eq("127.0.0.1")
    end

    it "rejects public binds without explicit opt-in" do
      expect do
        described_class.new(port: 0, bind_address: "0.0.0.0", provider: provider).start
      end.to raise_error(ArgumentError, /metrics endpoint.*public bind opt-in/)
    end

    it "serves Prometheus text metrics" do
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", provider: provider).start

      response = http_request("GET /metrics HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      headers, body = response.split("\r\n\r\n", 2)

      expect(headers).to include("HTTP/1.1 200 OK")
      expect(headers).to include("Content-Type: text/plain; version=0.0.4")
      expect(body).to include("activejob_temporal_active_workers 1.0")
    end

    it "returns no response body for HEAD requests" do
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", provider: provider).start

      response = http_request("HEAD /metrics HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      headers, body = response.split("\r\n\r\n", 2)

      expect(headers).to include("HTTP/1.1 200 OK")
      expect(headers).to include("Content-Length: 0")
      expect(body.to_s).to eq("")
    end

    it "returns method not allowed for unsupported methods" do
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", provider: provider).start

      response = http_request("POST /metrics HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

      expect(response).to include("HTTP/1.1 405 Method Not Allowed")
    end

    it "does not create a thread for each stalled client" do
      created_threads = Queue.new
      allow(Thread).to receive(:new).and_wrap_original do |original, *arguments, &block|
        created_threads << true
        original.call(*arguments, &block)
      end
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", provider: provider).start
      threads_after_start = created_threads.length

      stalled_sockets = Array.new(5) do
        TCPSocket.new("127.0.0.1", @server.port).tap do |socket|
          socket.write("GET /metrics HTTP/1.1\r\n")
        end
      end
      sleep 0.2

      expect(created_threads.length).to eq(threads_after_start)
    ensure
      stalled_sockets&.each(&:close)
    end

    it "releases workers held by partial request lines" do
      stub_const("#{described_class.name}::READ_TIMEOUT_SECONDS", 0.1)
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", provider: provider).start

      stalled_sockets = Array.new(described_class::CONNECTION_WORKERS) do
        TCPSocket.new("127.0.0.1", @server.port).tap do |socket|
          socket.write("GET /metrics HTTP/1.1")
        end
      end
      sleep 0.2

      response = http_request("GET /metrics HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

      expect(response).to include("HTTP/1.1 200 OK")
    ensure
      stalled_sockets&.each(&:close)
    end

    it "returns internal server error for provider failures and keeps serving later requests" do
      failing_provider = flaky_metrics_provider(described_class::CONNECTION_WORKERS)
      allow(ActiveJob::Temporal::Logger).to receive(:error)
      @server = described_class.new(port: 0, bind_address: "127.0.0.1", provider: failing_provider).start

      described_class::CONNECTION_WORKERS.times do
        response = http_request("GET /metrics HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

        expect(response).to include("HTTP/1.1 500 Internal Server Error")
        expect(response).to include("internal_server_error")
      end

      response = http_request("GET /metrics HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

      expect(response).to include("HTTP/1.1 200 OK")
      expect(response).to include("activejob_temporal_active_workers 1.0")
      expect(ActiveJob::Temporal::Logger).to have_received(:error).with(
        "metrics_request_failed",
        hash_including(error_class: "RuntimeError", message: "metrics render failed")
      ).exactly(described_class::CONNECTION_WORKERS).times
    end
  end

  private

  def flaky_metrics_provider(failures)
    calls = 0
    Object.new.tap do |provider|
      provider.define_singleton_method(:render) do
        calls += 1
        raise "metrics render failed" if calls <= failures

        "# TYPE activejob_temporal_active_workers gauge\nactivejob_temporal_active_workers 1.0\n"
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
end
