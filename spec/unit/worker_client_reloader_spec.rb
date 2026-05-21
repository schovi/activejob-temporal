# frozen_string_literal: true

require "spec_helper"

module WorkerClientReloaderSpecSupport
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

RSpec.describe ActiveJob::Temporal::WorkerClientReloader do
  it "rebuilds the client and assigns it to the worker" do
    worker = double("worker")
    logger = WorkerClientReloaderSpecSupport::FakeLogger.new
    fresh_client = instance_double("Temporalio::Client")
    reload_client = lambda do |&block|
      block.call(fresh_client)
      fresh_client
    end

    expect(worker).to receive(:client=).with(fresh_client)

    reloader = described_class.new(worker: worker, logger: logger, reload_client: reload_client)

    expect(reloader.reload(source: "file_watch")).to be(fresh_client)
    expect(logger.events).to include([:info, "certificate_reload_started", { source: "file_watch" }])
    expect(logger.events).to include([:info, "certificate_reload_succeeded", { source: "file_watch" }])
  end

  it "logs and reraises client rebuild failures" do
    worker = double("worker")
    logger = WorkerClientReloaderSpecSupport::FakeLogger.new
    reload_client = -> { raise ActiveJob::Temporal::Error, "connect failed" }
    reloader = described_class.new(worker: worker, logger: logger, reload_client: reload_client)

    expect(worker).not_to receive(:client=)

    expect { reloader.reload(source: "signal:HUP") }
      .to raise_error(ActiveJob::Temporal::Error, /connect failed/)
    expect(logger.events).to include(
      [:error, "certificate_reload_failed", hash_including(source: "signal:HUP", error_class: "ActiveJob::Temporal::Error")]
    )
  end

  it "logs and reraises worker replacement failures" do
    worker = double("worker")
    logger = WorkerClientReloaderSpecSupport::FakeLogger.new
    fresh_client = instance_double("Temporalio::Client")
    reload_client = lambda do |&block|
      block.call(fresh_client)
      fresh_client
    end

    allow(worker).to receive(:client=).with(fresh_client).and_raise(StandardError, "replace failed")

    reloader = described_class.new(worker: worker, logger: logger, reload_client: reload_client)

    expect { reloader.reload(source: "file_watch") }
      .to raise_error(StandardError, /replace failed/)
    expect(logger.events).to include(
      [:error, "certificate_reload_failed", hash_including(source: "file_watch", error_class: "StandardError")]
    )
  end
end
