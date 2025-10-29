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
        expect(attributes).to be_a(Temporalio::SearchAttributes)

        aj_class_key = Temporalio::SearchAttributes::Key.new("ajClass", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)
        aj_queue_key = Temporalio::SearchAttributes::Key.new("ajQueue", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)
        aj_job_id_key = Temporalio::SearchAttributes::Key.new("ajJobId", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)

        expect(attributes[aj_class_key]).to eq("SimpleJob")
        expect(attributes[aj_queue_key]).to eq("billing")
        expect(attributes[aj_job_id_key]).to eq("job-123")
      end

      it "includes the enqueue timestamp as a Time object" do
        aj_enqueued_at_key = Temporalio::SearchAttributes::Key.new("ajEnqueuedAt", Temporalio::SearchAttributes::IndexedValueType::TIME)

        expect(attributes[aj_enqueued_at_key]).to be_a(Time)
        expect(attributes[aj_enqueued_at_key]).to eq(timestamp)
      end

      it "omits ajTenantId when no tenant context exists" do
        aj_tenant_id_key = Temporalio::SearchAttributes::Key.new("ajTenantId", Temporalio::SearchAttributes::IndexedValueType::INTEGER)

        expect(attributes[aj_tenant_id_key]).to be_nil
      end
    end

    context "when queue name is not set" do
      let(:job) { SimpleJob.new }

      before do
        job.job_id = "job-456"
        job.queue_name = nil
      end

      it "falls back to the default queue" do
        aj_queue_key = Temporalio::SearchAttributes::Key.new("ajQueue", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)

        expect(attributes[aj_queue_key]).to eq("default")
      end
    end

    context "when job has a tenant-aware argument" do
      let(:tenant_context) { TenantContext.new(456) }
      let(:job) { SimpleJob.new([tenant_context]) }

      before do
        job.job_id = "job-789"
        job.queue_name = "multitenant"
      end

      it "includes ajTenantId" do
        aj_tenant_id_key = Temporalio::SearchAttributes::Key.new("ajTenantId", Temporalio::SearchAttributes::IndexedValueType::INTEGER)

        expect(attributes[aj_tenant_id_key]).to eq(456)
      end
    end

    context "when the first argument does not respond to tenant_id" do
      let(:job) { SimpleJob.new([Object.new]) }

      before do
        job.job_id = "job-999"
        job.queue_name = "ops"
      end

      it "does not include ajTenantId" do
        aj_tenant_id_key = Temporalio::SearchAttributes::Key.new("ajTenantId", Temporalio::SearchAttributes::IndexedValueType::INTEGER)

        expect(attributes[aj_tenant_id_key]).to be_nil
      end
    end

    context "when arguments are nil" do
      let(:job) { SimpleJob.new(nil) }

      before do
        job.job_id = "job-555"
        job.queue_name = "ops"
      end

      it "handles nil arguments without raising and omits ajTenantId" do
        aj_tenant_id_key = Temporalio::SearchAttributes::Key.new("ajTenantId", Temporalio::SearchAttributes::IndexedValueType::INTEGER)

        expect { attributes }.not_to raise_error
        expect(attributes[aj_tenant_id_key]).to be_nil
      end
    end
  end
end
