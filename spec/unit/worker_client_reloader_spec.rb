# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/worker_runtime"

module WorkerClientReloaderSpecSupport
  class FakeWorker
    attr_accessor :client
  end

  class FailingWorker
    def client=(_client)
      raise StandardError, "replace failed"
    end
  end

  class FakeLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def log_event(event_name, attributes = {})
      @events << [:info, event_name, attributes]
    end

    def error(event_name, attributes = {})
      @events << [:error, event_name, attributes]
    end
  end
end

describe ActiveJob::Temporal::WorkerClientReloader do
  it "rebuilds the client and assigns it to the worker" do
    worker = WorkerClientReloaderSpecSupport::FakeWorker.new
    logger = WorkerClientReloaderSpecSupport::FakeLogger.new
    fresh_client = Object.new
    reload_client = lambda do |&block|
      block.call(fresh_client)
      fresh_client
    end

    reloader = described_class.new(worker: worker, logger: logger, reload_client: reload_client)

    assert_same fresh_client, reloader.reload(source: "credential_refresh")
    assert_same fresh_client, worker.client
    assert_includes logger.events, [:info, "certificate_reload_started", { source: "credential_refresh" }]
    assert_includes logger.events, [:info, "certificate_reload_succeeded", { source: "credential_refresh" }]
  end

  it "logs and reraises client rebuild failures" do
    worker = WorkerClientReloaderSpecSupport::FakeWorker.new
    logger = WorkerClientReloaderSpecSupport::FakeLogger.new
    reload_client = -> { raise ActiveJob::Temporal::Error, "connect failed" }
    reloader = described_class.new(worker: worker, logger: logger, reload_client: reload_client)

    error = assert_raises(ActiveJob::Temporal::Error) { reloader.reload(source: "signal:HUP") }
    assert_match(/connect failed/, error.message)
    assert_nil worker.client
    assert_reload_failed_event logger.events,
                               source: "signal:HUP",
                               error_class: "ActiveJob::Temporal::Error"
  end

  it "logs and reraises worker replacement failures" do
    worker = WorkerClientReloaderSpecSupport::FailingWorker.new
    logger = WorkerClientReloaderSpecSupport::FakeLogger.new
    fresh_client = Object.new
    reload_client = lambda do |&block|
      block.call(fresh_client)
      fresh_client
    end

    reloader = described_class.new(worker: worker, logger: logger, reload_client: reload_client)

    error = assert_raises(StandardError) { reloader.reload(source: "credential_refresh") }
    assert_match(/replace failed/, error.message)
    assert_reload_failed_event logger.events, source: "credential_refresh", error_class: "StandardError"
  end

  def assert_reload_failed_event(events, source:, error_class:)
    event = events.find do |level, event_name, attributes|
      level == :error &&
        event_name == "certificate_reload_failed" &&
        attributes[:source] == source &&
        attributes[:error_class] == error_class
    end

    refute_nil event
  end
end
