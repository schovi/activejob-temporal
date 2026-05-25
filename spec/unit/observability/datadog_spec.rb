# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/observability/datadog"

RSpec.describe ActiveJob::Temporal::Observability::Datadog do
  let(:statsd) { double("Statsd", increment: nil, histogram: nil, gauge: nil) }
  let(:span) { double("Span", set_tag: nil) }
  let(:payload) do
    {
      job_class: "ExampleJob",
      queue: "critical",
      workflow_id: "workflow-1",
      namespace: "default",
      task_queue: "workers"
    }
  end
  let(:metric_tags) do
    contain_exactly(
      "job_class:ExampleJob",
      "queue:critical",
      "namespace:default",
      "task_queue:workers"
    )
  end

  before do
    stub_const("Datadog", Module.new)
    stub_const("Datadog::Tracing", Module.new)
    stub_const("Datadog::Tracing::Contrib", Module.new)
    stub_const("Datadog::Tracing::Contrib::HTTP", Module.new)
    Datadog::Tracing.define_singleton_method(:trace) { |_name, **_options| nil }
    Datadog::Tracing.define_singleton_method(:active_trace) { nil }
    Datadog::Tracing::Contrib::HTTP.define_singleton_method(:inject) { |_digest, _carrier| nil }
    Datadog::Tracing::Contrib::HTTP.define_singleton_method(:extract) { |_carrier| nil }
    allow(Datadog::Tracing).to receive(:trace).and_yield(span)
  end

  it "creates APM spans and DogStatsD metrics for job execution" do
    adapter = described_class.new(statsd: statsd)

    result = adapter.instrument(:perform, payload) { :ok }

    expect(result).to be(:ok)
    expect(Datadog::Tracing).to have_received(:trace).with(
      "activejob_temporal.perform",
      hash_including(service: "activejob-temporal", resource: "ExampleJob")
    )
    expect(span).to have_received(:set_tag).with("activejob_temporal.workflow_id", "workflow-1")
    expect(statsd).to have_received(:increment).with(
      "activejob_temporal.jobs.completed",
      tags: metric_tags
    )
    expect(statsd).to have_received(:histogram).with(
      "activejob_temporal.job_duration.seconds",
      kind_of(Float),
      tags: metric_tags
    )
  end

  it "records point metrics through DogStatsD" do
    adapter = described_class.new(statsd: statsd)

    adapter.record(:enqueue, payload)
    adapter.record(:active_tasks, task_queue: "default", count: 2)

    expect(statsd).to have_received(:increment).with(
      "activejob_temporal.jobs.enqueued",
      tags: metric_tags
    )
    expect(statsd).to have_received(:gauge).with(
      "activejob_temporal.active_tasks",
      2,
      tags: include("task_queue:default")
    )
  end

  it "omits workflow_id from failure, retry, and payload size metric tags" do
    stub_const("DatadogSpecExampleError", Class.new(StandardError))
    adapter = described_class.new(statsd: statsd)

    expect do
      adapter.instrument(:perform, payload) { raise DatadogSpecExampleError }
    end.to raise_error(DatadogSpecExampleError)

    adapter.record(:retry, payload.merge(error: "DatadogSpecExampleError"))
    adapter.record(:payload_serialize, payload.merge(bytes: 512))

    expect(statsd).to have_received(:increment).with(
      "activejob_temporal.jobs.failed",
      tags: contain_exactly(
        "job_class:ExampleJob",
        "queue:critical",
        "namespace:default",
        "task_queue:workers",
        "error:DatadogSpecExampleError"
      )
    )
    expect(statsd).to have_received(:increment).with(
      "activejob_temporal.retries",
      tags: contain_exactly(
        "job_class:ExampleJob",
        "queue:critical",
        "namespace:default",
        "task_queue:workers",
        "error:DatadogSpecExampleError"
      )
    )
    expect(statsd).to have_received(:histogram).with(
      "activejob_temporal.job_duration.seconds",
      kind_of(Float),
      tags: metric_tags
    )
    expect(statsd).to have_received(:histogram).with(
      "activejob_temporal.payload_size.bytes",
      512,
      tags: metric_tags
    )
  end

  it "injects Datadog trace context into a carrier" do
    trace = double("Trace", to_digest: "digest")
    adapter = described_class.new(statsd: statsd)
    allow(Datadog::Tracing).to receive(:active_trace).and_return(trace)
    allow(Datadog::Tracing::Contrib::HTTP).to receive(:inject) do |_digest, carrier|
      carrier["x-datadog-trace-id"] = "123"
    end

    expect(adapter.trace_context_for_enqueue({})).to eq("x-datadog-trace-id" => "123")
  end
end
