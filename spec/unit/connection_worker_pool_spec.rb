# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "activejob/temporal/connection_worker_pool"

describe ActiveJob::Temporal::ConnectionWorkerPool do
  let(:connection_class) do
    Struct.new(:closed_connections) do
      def close
        closed_connections << self
      end
    end
  end

  after do
    @pool&.stop(timeout: 1)
  end

  it "logs handler failures, closes the connection, and keeps the worker alive" do
    failed_connection = connection_class.new(Queue.new)
    successful_connection = connection_class.new(Queue.new)
    handled_connections = Queue.new

    logger_errors = call_recorded_method(ActiveJob::Temporal::Logger, :error)

    @pool = described_class.new(size: 1, queue_size: 2, name: "test-pool") do |connection|
      raise "handler failed" if connection.equal?(failed_connection)

      handled_connections << connection
    end.start

    assert @pool.enqueue(failed_connection)
    assert_same failed_connection, pop_queue(failed_connection.closed_connections)

    error_call = logger_errors.calls_for(:error).find do |call|
      call.arguments == ["connection_worker_handler_failed"]
    end
    refute_nil error_call
    assert_equal "test-pool", error_call.keywords.fetch(:pool)
    assert_equal "RuntimeError", error_call.keywords.fetch(:error_class)
    assert_equal "handler failed", error_call.keywords.fetch(:message)

    assert @pool.enqueue(successful_connection)
    assert_same successful_connection, pop_queue(handled_connections)
  end

  def pop_queue(queue)
    Timeout.timeout(1) { queue.pop }
  end
end
