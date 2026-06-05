# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/observability/opentelemetry"

describe ActiveJob::Temporal::Observability::OpenTelemetry do
  it "creates spans with job correlation attributes" do
    spans = []
    tracer = Class.new do
      def initialize(spans)
        @spans = spans
      end

      def in_span(name, attributes:)
        @spans << [name, attributes]
        yield Object.new.tap { |span| span.define_singleton_method(:record_exception) { |_error| nil } }
      end
    end.new(spans)
    propagation = Class.new do
      def extract(_carrier) = nil
    end.new
    adapter = described_class.new(tracer: tracer, propagation: propagation)

    result = adapter.instrument(
      :perform,
      job_class: "ExampleJob",
      job_id: "job-1",
      queue: "critical",
      workflow_id: "workflow-1"
    ) { :ok }

    assert_same :ok, result
    span_name, attributes = spans.first
    assert_equal "activejob_temporal.perform", span_name
    assert_equal "ExampleJob", attributes.fetch("activejob_temporal.job_class")
    assert_equal "job-1", attributes.fetch("activejob_temporal.job_id")
    assert_equal "critical", attributes.fetch("activejob_temporal.queue")
    assert_equal "workflow-1", attributes.fetch("activejob_temporal.workflow_id")
  end

  it "injects OpenTelemetry trace context into a carrier" do
    propagation = Class.new do
      def inject(carrier)
        carrier["traceparent"] = "00-trace-span-01"
      end
    end.new
    adapter = described_class.new(tracer: Object.new, propagation: propagation)

    assert_equal({ "traceparent" => "00-trace-span-01" }, adapter.trace_context_for_enqueue({}))
  end
end
