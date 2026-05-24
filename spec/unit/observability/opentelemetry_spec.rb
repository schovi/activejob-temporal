# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/observability/opentelemetry"

RSpec.describe ActiveJob::Temporal::Observability::OpenTelemetry do
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
    propagation = double("Propagation", extract: nil)
    adapter = described_class.new(tracer: tracer, propagation: propagation)

    result = adapter.instrument(
      :perform,
      job_class: "ExampleJob",
      job_id: "job-1",
      queue: "critical",
      workflow_id: "workflow-1"
    ) { :ok }

    expect(result).to be(:ok)
    expect(spans).to include(
      [
        "activejob_temporal.perform",
        hash_including(
          "activejob_temporal.job_class" => "ExampleJob",
          "activejob_temporal.job_id" => "job-1",
          "activejob_temporal.queue" => "critical",
          "activejob_temporal.workflow_id" => "workflow-1"
        )
      ]
    )
  end

  it "injects OpenTelemetry trace context into a carrier" do
    propagation = double("Propagation")
    allow(propagation).to receive(:inject) { |carrier| carrier["traceparent"] = "00-trace-span-01" }
    adapter = described_class.new(tracer: double("Tracer"), propagation: propagation)

    expect(adapter.trace_context_for_enqueue({})).to eq("traceparent" => "00-trace-span-01")
  end
end
