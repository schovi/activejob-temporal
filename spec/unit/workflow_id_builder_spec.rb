# frozen_string_literal: true

require "spec_helper"
require_relative "../fixtures/sample_jobs"

RSpec.describe ActiveJob::Temporal::WorkflowIdBuilder do
  subject(:builder) { described_class.new }

  describe "#build" do
    let(:job) do
      job = SimpleJob.new
      job.job_id = "abc-123"
      job
    end

    it "returns the default workflow ID format" do
      expect(builder.build(job)).to eq("ajwf:SimpleJob:abc-123")
    end

    it "is deterministic for the same job instance" do
      expect(builder.build(job)).to eq(builder.build(job))
    end

    it "includes the job class name" do
      scheduled_job = ScheduledJob.new
      scheduled_job.job_id = job.job_id

      expect(builder.build(scheduled_job)).to eq("ajwf:ScheduledJob:abc-123")
      expect(builder.build(scheduled_job)).not_to eq(builder.build(job))
    end

    it "includes the job ID" do
      other_job = SimpleJob.new
      other_job.job_id = "def-456"

      expect(builder.build(other_job)).to eq("ajwf:SimpleJob:def-456")
      expect(builder.build(other_job)).not_to eq(builder.build(job))
    end

    it "uses the injected strategy when provided" do
      custom_builder = described_class.new(->(job) { "custom:#{job.job_id}" })

      expect(custom_builder.build(job)).to eq("custom:abc-123")
    end
  end

  describe "#build_from_job_class" do
    it "returns the same format without a job instance" do
      workflow_id = builder.build_from_job_class(SimpleJob, "550e8400-e29b-41d4-a716-446655440000")

      expect(workflow_id).to eq("ajwf:SimpleJob:550e8400-e29b-41d4-a716-446655440000")
    end
  end
end
