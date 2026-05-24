# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::Observability do
  after do
    described_class.reset!
  end

  it "emits Rails notifications even when no adapters are enabled" do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("enqueue.activejob_temporal") do |*arguments|
      events << ActiveSupport::Notifications::Event.new(*arguments)
    end

    described_class.emit(:enqueue, job_class: "NotificationJob")

    expect(events.map(&:payload)).to include(hash_including(job_class: "NotificationJob"))
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it "routes point and timed events through configured adapters" do
    adapter_class = Class.new(described_class::Adapter) do
      attr_reader :records, :instruments

      def initialize
        super(:observability_spec)
        @records = []
        @instruments = []
      end

      def record(event_name, payload)
        records << [event_name, payload]
      end

      def instrument(event_name, payload)
        instruments << [event_name, payload]
        yield
      end
    end
    described_class.register_adapter(:observability_spec, adapter_class)
    adapter = ActiveJob::Temporal.config.observability.use(:observability_spec)

    described_class.emit(:enqueue, job_class: "AdapterJob")
    result = described_class.instrument(:perform, job_class: "AdapterJob") { :performed }

    expect(result).to be(:performed)
    expect(adapter.records).to include([:enqueue, hash_including(job_class: "AdapterJob")])
    expect(adapter.instruments).to include([:perform, hash_including(job_class: "AdapterJob")])
  end

  it "injects adapter trace context into payload observability metadata" do
    adapter_class = Class.new(described_class::Adapter) do
      def initialize
        super(:trace_spec)
      end

      def trace_context_for_enqueue(_payload)
        { "traceparent" => "00-trace-span-01" }
      end
    end
    described_class.register_adapter(:trace_spec, adapter_class)
    ActiveJob::Temporal.config.observability.use(:trace_spec)
    payload = {}

    described_class.inject_trace_context(payload, job_class: "TraceJob")

    expect(payload).to include(
      observability: {
        "trace_context" => {
          "trace_spec" => { "traceparent" => "00-trace-span-01" }
        }
      }
    )
  end

  it "raises explanatory missing dependency errors from adapters" do
    adapter = Class.new(described_class::Adapter) do
      def initialize
        super(:missing_dependency_spec)
      end

      def validate_dependencies!
        require_dependency("missing-gem", "missing/path", "Missing")
      end
    end.new
    allow(adapter).to receive(:require)
      .with("missing/path")
      .and_raise(LoadError, "cannot load such file -- missing/path")

    expect { adapter.validate! }
      .to raise_error(described_class::MissingDependency, /missing-gem/)
  end
end
