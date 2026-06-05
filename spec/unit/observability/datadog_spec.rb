# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/observability/datadog"

module DatadogSpecSupport
  class FakeStatsd
    attr_reader :calls

    def initialize
      @calls = []
    end

    def increment(metric, **keywords)
      calls << { method_name: :increment, metric: metric, value: nil, keywords: keywords }
    end

    def histogram(metric, value, **keywords)
      calls << { method_name: :histogram, metric: metric, value: value, keywords: keywords }
    end

    def gauge(metric, value, **keywords)
      calls << { method_name: :gauge, metric: metric, value: value, keywords: keywords }
    end
  end

  class FakeSpan
    attr_reader :tags

    def initialize
      @tags = []
    end

    def set_tag(name, value)
      tags << [name, value]
    end
  end

  class FakeTrace
    def to_digest = "digest"
  end
end

describe ActiveJob::Temporal::Observability::Datadog do
  let(:statsd) { DatadogSpecSupport::FakeStatsd.new }
  let(:span) { DatadogSpecSupport::FakeSpan.new }
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
    [
      "job_class:ExampleJob",
      "queue:critical",
      "namespace:default",
      "task_queue:workers"
    ]
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
    @trace_calls = call_recorded_method(Datadog::Tracing, :trace) do |_name, **_options, &block|
      block.call(span)
    end
  end

  it "creates APM spans and DogStatsD metrics for job execution" do
    adapter = described_class.new(statsd: statsd)

    result = adapter.instrument(:perform, payload) { :ok }

    assert_same :ok, result

    trace_call = @trace_calls.calls_for(:trace).first
    assert_equal ["activejob_temporal.perform"], trace_call.arguments
    assert_hash_includes({ service: "activejob-temporal", resource: "ExampleJob" }, trace_call.keywords)
    assert_includes span.tags, ["activejob_temporal.workflow_id", "workflow-1"]

    completed_call = assert_statsd_call(:increment, "activejob_temporal.jobs.completed")
    duration_call = assert_statsd_call(:histogram, "activejob_temporal.job_duration.seconds")
    assert_unordered_equal metric_tags, completed_call[:keywords][:tags]
    assert_kind_of Float, duration_call[:value]
    assert_unordered_equal metric_tags, duration_call[:keywords][:tags]
  end

  it "records point metrics through DogStatsD" do
    adapter = described_class.new(statsd: statsd)

    adapter.record(:enqueue, payload)
    adapter.record(:active_tasks, task_queue: "default", count: 2)

    enqueue_call = assert_statsd_call(:increment, "activejob_temporal.jobs.enqueued")
    active_tasks_call = assert_statsd_call(:gauge, "activejob_temporal.active_tasks")
    assert_unordered_equal metric_tags, enqueue_call[:keywords][:tags]
    assert_equal 2, active_tasks_call[:value]
    assert_includes active_tasks_call[:keywords][:tags], "task_queue:default"
  end

  it "omits workflow_id from failure, retry, and payload size metric tags" do
    stub_const("DatadogSpecExampleError", Class.new(StandardError))
    adapter = described_class.new(statsd: statsd)

    assert_raises(DatadogSpecExampleError) do
      adapter.instrument(:perform, payload) { raise DatadogSpecExampleError }
    end

    adapter.record(:retry, payload.merge(error: "DatadogSpecExampleError"))
    adapter.record(:payload_serialize, payload.merge(bytes: 512))

    error_tags = [
      "job_class:ExampleJob",
      "queue:critical",
      "namespace:default",
      "task_queue:workers",
      "error:DatadogSpecExampleError"
    ]

    failed_call = assert_statsd_call(:increment, "activejob_temporal.jobs.failed")
    retry_call = assert_statsd_call(:increment, "activejob_temporal.retries")
    duration_call = assert_statsd_call(:histogram, "activejob_temporal.job_duration.seconds")
    payload_size_call = assert_statsd_call(:histogram, "activejob_temporal.payload_size.bytes")

    assert_unordered_equal error_tags, failed_call[:keywords][:tags]
    assert_unordered_equal error_tags, retry_call[:keywords][:tags]
    assert_kind_of Float, duration_call[:value]
    assert_unordered_equal metric_tags, duration_call[:keywords][:tags]
    assert_equal 512, payload_size_call[:value]
    assert_unordered_equal metric_tags, payload_size_call[:keywords][:tags]
  end

  it "injects Datadog trace context into a carrier" do
    trace = DatadogSpecSupport::FakeTrace.new
    adapter = described_class.new(statsd: statsd)
    call_recorded_method(Datadog::Tracing, :active_trace, returns: trace)
    call_recorded_method(Datadog::Tracing::Contrib::HTTP, :inject) do |_digest, carrier|
      carrier["x-datadog-trace-id"] = "123"
    end

    assert_equal({ "x-datadog-trace-id" => "123" }, adapter.trace_context_for_enqueue({}))
  end

  private

  def assert_statsd_call(method_name, metric)
    call = statsd.calls.find do |candidate|
      candidate[:method_name] == method_name && candidate[:metric] == metric
    end

    refute_nil call
    call
  end
end
