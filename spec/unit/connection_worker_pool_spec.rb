# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "activejob/temporal/connection_worker_pool"

RSpec.describe ActiveJob::Temporal::ConnectionWorkerPool do
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

    allow(ActiveJob::Temporal::Logger).to receive(:error)

    @pool = described_class.new(size: 1, queue_size: 2, name: "test-pool") do |connection|
      raise "handler failed" if connection.equal?(failed_connection)

      handled_connections << connection
    end.start

    expect(@pool.enqueue(failed_connection)).to be(true)
    expect(pop_queue(failed_connection.closed_connections)).to be(failed_connection)
    expect(ActiveJob::Temporal::Logger).to have_received(:error).with(
      "connection_worker_handler_failed",
      hash_including(pool: "test-pool", error_class: "RuntimeError", message: "handler failed")
    )

    expect(@pool.enqueue(successful_connection)).to be(true)
    expect(pop_queue(handled_connections)).to be(successful_connection)
  end

  def pop_queue(queue)
    Timeout.timeout(1) { queue.pop }
  end
end
