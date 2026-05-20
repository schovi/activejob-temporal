# frozen_string_literal: true

require "spec_helper"
require_relative "../../fixtures/sample_jobs"
require "activejob/temporal/activities/aj_runner_activity"

RSpec.describe ActiveJob::Temporal::Activities::AjRunnerActivity do
  subject(:activity) { described_class.new }

  let(:workflow_id) { "wf-123" }
  let(:activity_info) { instance_double("Temporalio::Activity::Info", workflow_id: workflow_id) }
  let(:activity_context) { instance_double("Temporalio::Activity::Context", info: activity_info) }
  let(:args) { [42, "payload"] }
  let(:idempotency_key) { :aj_temporal_idempotency_key }
  let(:middleware_chain) { ActiveJob::Temporal::Middleware::Chain.new }

  before do
    # Mock the real SDK's Activity Context API
    allow(Temporalio::Activity::Context).to receive(:exist?).and_return(true)
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity_context)
    allow(ActiveJob::Temporal::Payload).to receive(:deserialize_args).and_return(args)
    allow(ActiveJob::Temporal::RetryMapper).to receive(:discard_exception?).and_return(false)
    allow(ActiveJob::Temporal.config).to receive(:middleware_chain).and_return(middleware_chain)
    allow(ActiveJob::Temporal::Metrics).to receive(:instrument_perform).and_call_original
    allow(ActiveJob::Temporal::Metrics).to receive(:record_retry)
  end

  describe "#execute" do
    it "instantiates the job, performs with deserialized args, and resets idempotency key" do
      job_instance = instance_double("RunnerSpecJob")
      job_class = class_double("RunnerSpecJob", new: job_instance).as_stubbed_const
      payload = { "job_class" => "RunnerSpecJob", "arguments" => ["raw"] }

      expect(ActiveJob::Temporal::Payload).to receive(:deserialize_args).with(payload).and_return(args)
      allow(job_instance).to receive(:perform) do |*received_args|
        expect(Thread.current[idempotency_key]).to eq("#{workflow_id}/runner")
        expect(received_args).to eq(args)
      end

      activity.execute(payload)

      expect(job_class).to have_received(:new)
      expect(job_instance).to have_received(:perform).with(*args)
      expect(Thread.current[idempotency_key]).to be_nil
    end

    it "re-raises retryable exceptions so Temporal can retry" do
      payload = { "job_class" => "RetryableJob" }
      job_instance = instance_double(RetryableJob.name)
      allow(RetryableJob).to receive(:new).and_return(job_instance)
      error = SampleJobError.new("boom")
      allow(job_instance).to receive(:perform).and_raise(error)

      expect do
        activity.execute(payload)
      end.to raise_error(error)

      expect(Thread.current[idempotency_key]).to be_nil
      expect(ActiveJob::Temporal::RetryMapper).to have_received(:discard_exception?).with(RetryableJob, error)
    end

    it "executes the job through configured middleware" do
      events = []
      middleware_class = Class.new do
        def initialize(events, idempotency_key)
          @events = events
          @idempotency_key = idempotency_key
        end

        def call(job)
          @events << [:before, job, Thread.current[@idempotency_key]]
          result = yield
          @events << [:after, result]
          result
        end
      end
      middleware_chain.add(middleware_class, events, idempotency_key)
      job_instance = instance_double("MiddlewareRunnerJob")
      class_double("MiddlewareRunnerJob", new: job_instance).as_stubbed_const
      payload = { "job_class" => "MiddlewareRunnerJob" }
      allow(job_instance).to receive(:perform) do |*received_args|
        events << [:perform, received_args]
        "performed"
      end

      expect(activity.execute(payload)).to eq("performed")
      expect(events).to eq([
                             [:before, job_instance, "#{workflow_id}/runner"],
                             [:perform, args],
                             [:after, "performed"]
                           ])
    end

    it "records job execution metrics around perform" do
      job_instance = instance_double("MetricsRunnerJob")
      class_double("MetricsRunnerJob", new: job_instance).as_stubbed_const
      payload = { "job_class" => "MetricsRunnerJob", "queue_name" => "critical" }
      allow(job_instance).to receive(:perform).and_return("performed")

      expect(activity.execute(payload)).to eq("performed")

      expect(ActiveJob::Temporal::Metrics).to have_received(:instrument_perform).with(payload)
    end

    it "records failed metrics for setup failures before perform starts" do
      previous_provider = ActiveJob::Temporal.config.metrics_provider
      payload = { "job_class" => "SetupFailureJob", "queue_name" => "critical" }
      error = ArgumentError.new("bad payload")
      ActiveJob::Temporal::Metrics.reset!
      ActiveJob::Temporal.config.metrics_provider = :prometheus
      allow(ActiveJob::Temporal::Payload).to receive(:deserialize_args).with(payload).and_raise(error)

      expect { activity.execute(payload) }.to raise_error(error)

      expect(ActiveJob::Temporal::Metrics.render).to include(
        'activejob_temporal_jobs_failed_total{class="SetupFailureJob",queue="critical",error="ArgumentError"} 1.0'
      )
    ensure
      ActiveJob::Temporal.config.metrics_provider = previous_provider if previous_provider
      ActiveJob::Temporal::Metrics.reset!
    end

    it "routes middleware exceptions through Temporal retry handling" do
      error = RuntimeError.new("middleware failed")
      middleware_class = Class.new do
        def initialize(error)
          @error = error
        end

        def call(_job)
          raise @error
        end
      end
      middleware_chain.add(middleware_class, error)
      payload = { "job_class" => "RetryableJob" }
      job_instance = instance_double(RetryableJob.name)
      allow(RetryableJob).to receive(:new).and_return(job_instance)
      allow(job_instance).to receive(:perform)

      expect { activity.execute(payload) }.to raise_error(error)

      expect(job_instance).not_to have_received(:perform)
      expect(ActiveJob::Temporal::RetryMapper).to have_received(:discard_exception?).with(RetryableJob, error)
      expect(Thread.current[idempotency_key]).to be_nil
    end

    it "records retry metrics for retry attempts that fail" do
      activity_info = instance_double("Temporalio::Activity::Info", workflow_id: workflow_id, attempt: 2)
      activity_context = instance_double("Temporalio::Activity::Context", info: activity_info)
      allow(Temporalio::Activity::Context).to receive(:current).and_return(activity_context)
      payload = { "job_class" => "RetryableJob", "queue_name" => "critical" }
      job_instance = instance_double(RetryableJob.name)
      allow(RetryableJob).to receive(:new).and_return(job_instance)
      error = SampleJobError.new("boom")
      allow(job_instance).to receive(:perform).and_raise(error)

      expect { activity.execute(payload) }.to raise_error(error)

      expect(ActiveJob::Temporal::Metrics).to have_received(:record_retry).with(payload, error)
    end

    it "wraps discard_on exceptions in non-retryable ApplicationError" do
      payload = { "job_class" => "DiscardOnlyJob" }
      job_instance = instance_double(DiscardOnlyJob.name)
      allow(DiscardOnlyJob).to receive(:new).and_return(job_instance)
      original_error = FatalJobError.new("fail fast")
      allow(job_instance).to receive(:perform).and_raise(original_error)
      allow(ActiveJob::Temporal::RetryMapper).to receive(:discard_exception?)
        .with(DiscardOnlyJob, original_error)
        .and_return(true)

      expect { activity.execute(payload) }
        .to raise_error(Temporalio::Error::ApplicationError) do |error|
          expect(error.non_retryable).to eq(true)
          expect(error.message).to eq(original_error.message)
        end

      expect(Thread.current[idempotency_key]).to be_nil
    end
  end
end
