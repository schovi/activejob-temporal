# frozen_string_literal: true

require "spec_helper"
require_relative "../fixtures/sample_jobs"

TenantContext = Struct.new(:tenant_id) unless defined?(TenantContext)

RSpec.describe ActiveJob::Temporal::SearchAttributes do
  describe ".for" do
    subject(:attributes) { described_class.for(job) }

    let(:timestamp) { Time.utc(2024, 1, 1, 12, 0, 0) }

    before do
      allow(Time).to receive(:now).and_return(timestamp)
    end

    context "with a basic job" do
      let(:job) { SimpleJob.new(["arg"]) }

      before do
        job.job_id = "job-123"
        job.queue_name = "billing"
      end

      it "builds keyword attributes" do
        expect(attributes).to include(
          ajClass: "SimpleJob",
          ajQueue: "billing",
          ajJobId: "job-123"
        )
      end

      it "includes the enqueue timestamp as a Time object" do
        expect(attributes[:ajEnqueuedAt]).to be_a(Time)
        expect(attributes[:ajEnqueuedAt]).to eq(timestamp)
      end

      it "omits ajTenantId when no tenant context exists" do
        expect(attributes).not_to have_key(:ajTenantId)
      end
    end

    context "when queue name is not set" do
      let(:job) { SimpleJob.new }

      before do
        job.job_id = "job-456"
        job.queue_name = nil
      end

      it "falls back to the default queue" do
        expect(attributes[:ajQueue]).to eq("default")
      end
    end

    context "when job has a tenant-aware argument" do
      let(:tenant_context) { TenantContext.new("tenant-456") }
      let(:job) { SimpleJob.new([tenant_context]) }

      before do
        job.job_id = "job-789"
        job.queue_name = "multitenant"
      end

      it "includes ajTenantId" do
        expect(attributes[:ajTenantId]).to eq("tenant-456")
      end
    end

    context "when the first argument does not respond to tenant_id" do
      let(:job) { SimpleJob.new([Object.new]) }

      before do
        job.job_id = "job-999"
        job.queue_name = "ops"
      end

      it "does not include ajTenantId" do
        expect(attributes).not_to have_key(:ajTenantId)
      end
    end
  end
end
