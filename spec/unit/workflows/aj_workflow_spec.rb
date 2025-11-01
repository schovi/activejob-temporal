# frozen_string_literal: true

require "spec_helper"
require "time"
require "activejob/temporal/workflows/aj_workflow"

module Temporalio
  module Workflow
    class << self
      def now
        @now || Time.utc(2024, 1, 1, 12, 0, 0)
      end

      def sleep(_duration); end

      def execute_activity(*)
        nil
      end
    end
  end
end

RSpec.describe ActiveJob::Temporal::Workflows::AjWorkflow do
  subject(:workflow) { described_class.new }

  let(:activity_timeout) { ActiveJob::Temporal.config.default_activity_timeout }
  let(:retry_policy_hash) do
    {
      initial_interval: 30.0,
      backoff_coefficient: 2.0,
      maximum_attempts: 3,
      non_retryable_error_types: []
    }
  end
  let(:base_payload) do
    {
      "job_class" => "SampleJob",
      "job_id" => "abc-123",
      "queue_name" => "default",
      "arguments" => [],
      "retry_policy" => retry_policy_hash
    }
  end

  before do
    stub_const("SampleJob", Class.new)
    allow(Temporalio::Workflow).to receive(:execute_activity).and_return(:activity_result)
    allow(Temporalio::Workflow).to receive(:sleep)
    allow(ActiveJob::Temporal::RetryMapper).to receive(:for).and_return({})
  end

  describe "#execute" do
    context "when payload has no scheduled_at" do
      it "invokes the activity immediately" do
        workflow.execute(base_payload)

        expect(Temporalio::Workflow).not_to have_received(:sleep)
        expect(Temporalio::Workflow).to have_received(:execute_activity) do |activity_class, payload, options|
          expect(activity_class).to eq(ActiveJob::Temporal::Activities::AjRunnerActivity)
          expect(payload).to eq(base_payload)
          expect(options[:start_to_close_timeout]).to eq(activity_timeout)
          expect(options[:retry_policy]).to be_a(Temporalio::RetryPolicy)
        end
      end
    end

    context "when payload is scheduled in the future" do
      it "sleeps for the exact delay before executing" do
        current_time = Time.utc(2024, 1, 1, 12, 0, 0)
        scheduled_time = current_time + 300
        payload = base_payload.merge("scheduled_at" => scheduled_time.iso8601)

        allow(Temporalio::Workflow).to receive(:now).and_return(current_time)

        workflow.execute(payload)

        expect(Temporalio::Workflow).to have_received(:sleep).with(be_within(1e-6).of(300.0))
        expect(Temporalio::Workflow).to have_received(:execute_activity) do |activity_class, payload_arg, options|
          expect(activity_class).to eq(ActiveJob::Temporal::Activities::AjRunnerActivity)
          expect(payload_arg).to eq(payload)
          expect(options[:start_to_close_timeout]).to eq(activity_timeout)
          expect(options[:retry_policy]).to be_a(Temporalio::RetryPolicy)
        end
      end
    end

    context "when scheduled_at is in the past" do
      it "skips sleeping and runs immediately" do
        current_time = Time.utc(2024, 1, 1, 12, 0, 0)
        payload = base_payload.merge("scheduled_at" => (current_time - 120).iso8601)

        allow(Temporalio::Workflow).to receive(:now).and_return(current_time)

        workflow.execute(payload)

        expect(Temporalio::Workflow).not_to have_received(:sleep)
        expect(Temporalio::Workflow).to have_received(:execute_activity)
      end
    end

    context "when retry policy metadata is available" do
      it "passes the retry policy through to the activity call" do
        custom_retry_policy = {
          initial_interval: 15.0,
          backoff_coefficient: 1.5,
          maximum_attempts: 5,
          non_retryable_error_types: []
        }
        payload = base_payload.merge("retry_policy" => custom_retry_policy)

        workflow.execute(payload)

        expect(Temporalio::Workflow).to have_received(:execute_activity) do |activity_class, payload_arg, options|
          expect(activity_class).to eq(ActiveJob::Temporal::Activities::AjRunnerActivity)
          expect(payload_arg).to eq(payload)
          expect(options[:start_to_close_timeout]).to eq(activity_timeout)
          expect(options[:retry_policy]).to be_a(Temporalio::RetryPolicy)
        end
      end
    end
  end
end
