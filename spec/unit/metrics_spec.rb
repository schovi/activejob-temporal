# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::Metrics do
  describe ".record_enqueue" do
    it "labels enqueue metrics with the ActiveJob queue" do
      previous_provider = ActiveJob::Temporal.config.metrics_provider
      described_class.reset!
      ActiveJob::Temporal.config.metrics_provider = :prometheus
      job_class = Class.new(ActiveJob::Base) do
        def self.name = "MetricsFacadeJob"

        def perform; end
      end
      job = job_class.new
      job.queue_name = "default"

      described_class.record_enqueue(job: job, duplicate: false)

      expect(described_class.render).to include(
        'activejob_temporal_jobs_enqueued_total{class="MetricsFacadeJob",queue="default"} 1.0'
      )
    ensure
      ActiveJob::Temporal.config.metrics_provider = previous_provider if previous_provider
      described_class.reset!
    end
  end
end
