# frozen_string_literal: true

require "spec_helper"
require_relative "../fixtures/sample_jobs"

RSpec.describe ActiveJob::Temporal::Adapter do
  describe ".build_workflow_id" do
    context "with a simple job" do
      let(:job) do
        job = SimpleJob.new
        job.job_id = "abc-123"
        job
      end

      it "returns workflow ID in the expected format" do
        workflow_id = described_class.build_workflow_id(job)

        expect(workflow_id).to eq("ajwf:SimpleJob:abc-123")
      end

      it "is deterministic for the same job instance" do
        first = described_class.build_workflow_id(job)
        second = described_class.build_workflow_id(job)

        expect(first).to eq(second)
      end
    end

    context "with different job classes sharing job_id" do
      let(:simple_job) do
        job = SimpleJob.new
        job.job_id = "shared-id"
        job
      end

      let(:scheduled_job) do
        job = ScheduledJob.new
        job.job_id = "shared-id"
        job
      end

      it "produces different workflow IDs" do
        simple_id = described_class.build_workflow_id(simple_job)
        scheduled_id = described_class.build_workflow_id(scheduled_job)

        expect(simple_id).to eq("ajwf:SimpleJob:shared-id")
        expect(scheduled_id).to eq("ajwf:ScheduledJob:shared-id")
        expect(simple_id).not_to eq(scheduled_id)
      end
    end

    context "with the same job class and different job IDs" do
      it "returns unique workflow IDs" do
        job_one = SimpleJob.new
        job_one.job_id = "id-1"

        job_two = SimpleJob.new
        job_two.job_id = "id-2"

        id_one = described_class.build_workflow_id(job_one)
        id_two = described_class.build_workflow_id(job_two)

        expect(id_one).to eq("ajwf:SimpleJob:id-1")
        expect(id_two).to eq("ajwf:SimpleJob:id-2")
        expect(id_one).not_to eq(id_two)
      end
    end
  end
end
