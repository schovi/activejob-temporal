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

  describe ".resolve_task_queue" do
    let(:job) { SimpleJob.new }

    context "when no prefix is configured" do
      before do
        allow(ActiveJob::Temporal.config).to receive(:task_queue_prefix).and_return(nil)
      end

      it "returns the job queue name" do
        job.queue_name = "billing"

        expect(described_class.resolve_task_queue(job)).to eq("billing")
      end

      it "falls back to the default queue when queue_name is nil" do
        job.queue_name = nil

        expect(described_class.resolve_task_queue(job)).to eq("default")
      end

      it "treats blank queue names as default" do
        job.queue_name = "   "

        expect(described_class.resolve_task_queue(job)).to eq("default")
      end
    end

    context "when a prefix is configured" do
      before do
        allow(ActiveJob::Temporal.config).to receive(:task_queue_prefix).and_return("prod-")
      end

      it "prepends the prefix to the queue name" do
        job.queue_name = "billing"

        expect(described_class.resolve_task_queue(job)).to eq("prod-billing")
      end

      it "prepends the prefix to the default queue" do
        job.queue_name = nil

        expect(described_class.resolve_task_queue(job)).to eq("prod-default")
      end

      it "works for other queue names" do
        job.queue_name = "mailers"

        expect(described_class.resolve_task_queue(job)).to eq("prod-mailers")
      end
    end

    context "when the prefix is an empty string" do
      before do
        allow(ActiveJob::Temporal.config).to receive(:task_queue_prefix).and_return("")
      end

      it "treats an empty prefix as absent" do
        job.queue_name = "exports"

        expect(described_class.resolve_task_queue(job)).to eq("exports")
      end
    end
  end
end
