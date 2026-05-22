# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::Metrics::Prometheus do
  def rendered_metrics
    metrics.render
  end

  describe "#record_enqueue" do
    subject(:metrics) { described_class.new }

    it "increments enqueued job counters by class and queue" do
      metrics.record_enqueue(job_class: "ExampleJob", queue: "critical")

      expect(rendered_metrics).to include(
        'activejob_temporal_jobs_enqueued_total{class="ExampleJob",queue="critical"} 1.0'
      )
    end

    it "does not count duplicate enqueue attempts" do
      metrics.record_enqueue(job_class: "ExampleJob", queue: "critical", duplicate: true)

      expect(rendered_metrics).not_to include("activejob_temporal_jobs_enqueued_total{")
    end
  end

  describe "#observe_payload_size" do
    subject(:metrics) { described_class.new }

    it "observes serialized payload sizes by job class" do
      metrics.observe_payload_size(job_class: "ExampleJob", bytes: 2048)

      expect(rendered_metrics).to include('activejob_temporal_payload_size_bytes_sum{class="ExampleJob"} 2048.0')
      expect(rendered_metrics).to include('activejob_temporal_payload_size_bytes_count{class="ExampleJob"} 1.0')
    end
  end

  describe "#instrument_perform" do
    subject(:metrics) { described_class.new(monotonic_clock: clock) }

    let(:clock_values) { [100.0, 100.25] }
    let(:clock) { -> { clock_values.shift } }

    it "records completed jobs and runner duration" do
      result = metrics.instrument_perform(job_class: "ExampleJob", queue: "critical") { :ok }

      expect(result).to be(:ok)
      expect(rendered_metrics).to include(
        'activejob_temporal_jobs_completed_total{class="ExampleJob",queue="critical"} 1.0'
      )
      expect(rendered_metrics).to include('activejob_temporal_job_duration_seconds_sum{class="ExampleJob"} 0.25')
    end

    it "records failed jobs and duration before re-raising" do
      error = RuntimeError.new("boom")

      expect do
        metrics.instrument_perform(job_class: "ExampleJob", queue: "critical") { raise error }
      end.to raise_error(error)

      expect(rendered_metrics).to include(
        'activejob_temporal_jobs_failed_total{class="ExampleJob",queue="critical",error="RuntimeError"} 1.0'
      )
      expect(rendered_metrics).to include('activejob_temporal_job_duration_seconds_sum{class="ExampleJob"} 0.25')
    end

    it "normalizes failed job errors to a bounded label" do
      error = Class.new(RuntimeError).new("boom")

      expect do
        metrics.instrument_perform(job_class: "ExampleJob", queue: "critical") { raise error }
      end.to raise_error(error)

      expect(rendered_metrics).to include(
        'activejob_temporal_jobs_failed_total{class="ExampleJob",queue="critical",error="RuntimeError"} 1.0'
      )
    end
  end

  describe "worker gauges" do
    subject(:metrics) { described_class.new }

    it "tracks active workers and activity tasks" do
      metrics.record_worker_started
      metrics.record_active_tasks(3)

      expect(rendered_metrics).to include("activejob_temporal_active_workers 1.0")
      expect(rendered_metrics).to include("activejob_temporal_active_tasks 3.0")

      metrics.record_worker_stopped

      expect(rendered_metrics).to include("activejob_temporal_active_workers 0.0")
    end
  end

  describe "#record_retry" do
    subject(:metrics) { described_class.new }

    it "increments retry counters by class and error" do
      metrics.record_retry(job_class: "ExampleJob", error: "RuntimeError")

      expect(rendered_metrics).to include(
        'activejob_temporal_retries_total{class="ExampleJob",error="RuntimeError"} 1.0'
      )
    end

    it "normalizes unknown retry errors to a bounded label" do
      metrics.record_retry(job_class: "ExampleJob", error: "MyApp::TransientError")

      expect(rendered_metrics).to include(
        'activejob_temporal_retries_total{class="ExampleJob",error="StandardError"} 1.0'
      )
    end
  end
end
