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

  before do
    # Mock the real SDK's Activity Context API
    allow(Temporalio::Activity::Context).to receive(:exist?).and_return(true)
    allow(Temporalio::Activity::Context).to receive(:current).and_return(activity_context)
    allow(ActiveJob::Temporal::Payload).to receive(:deserialize_args).and_return(args)
    allow(ActiveJob::Temporal::RetryMapper).to receive(:discard_exception?).and_return(false)
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
