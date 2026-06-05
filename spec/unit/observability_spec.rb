# frozen_string_literal: true

require "spec_helper"

describe ActiveJob::Temporal::Observability do
  after do
    described_class.reset!
  end

  it "emits Rails notifications even when no adapters are enabled" do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("enqueue.activejob_temporal") do |*arguments|
      events << ActiveSupport::Notifications::Event.new(*arguments)
    end

    described_class.emit(:enqueue, job_class: "NotificationJob")

    matching_event = events.any? { |event| event.payload[:job_class] == "NotificationJob" }
    assert matching_event
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

    enqueue_recorded = adapter.records.any? do |event_name, payload|
      event_name == :enqueue && payload[:job_class] == "AdapterJob"
    end
    perform_instrumented = adapter.instruments.any? do |event_name, payload|
      event_name == :perform && payload[:job_class] == "AdapterJob"
    end

    assert_same :performed, result
    assert enqueue_recorded
    assert perform_instrumented
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

    assert_equal(
      {
        observability: {
          "trace_context" => {
            "trace_spec" => { "traceparent" => "00-trace-span-01" }
          }
        }
      },
      payload
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
    load_error = LoadError.new("cannot load such file -- missing/path")
    call_recorded_method(adapter, :require, raises: load_error)

    error = assert_raises(described_class::MissingDependency) { adapter.validate! }
    assert_match(/missing-gem/, error.message)
  end
end
