# frozen_string_literal: true

require "spec_helper"
require_relative "../fixtures/sample_jobs"

TenantContext = Struct.new(:tenant_id) unless defined?(TenantContext)

describe ActiveJob::Temporal::SearchAttributes do
  describe ".for" do
    let(:attributes) { described_class.for(job) }

    let(:timestamp) { Time.utc(2024, 1, 1, 12, 0, 0) }

    before do
      call_recorded_method(Time, :now, returns: timestamp)
    end

    describe "with a basic job" do
      let(:job) { SimpleJob.new(["arg"]) }

      before do
        job.job_id = "job-123"
        job.queue_name = "billing"
      end

      it "builds keyword attributes" do
        assert_kind_of Temporalio::SearchAttributes, attributes

        aj_class_key = search_attribute_key("ajClass", :KEYWORD)
        aj_queue_key = search_attribute_key("ajQueue", :KEYWORD)
        aj_job_id_key = search_attribute_key("ajJobId", :KEYWORD)

        assert_equal "SimpleJob", attributes[aj_class_key]
        assert_equal "billing", attributes[aj_queue_key]
        assert_equal "job-123", attributes[aj_job_id_key]
      end

      it "includes the enqueue timestamp as a Time object" do
        aj_enqueued_at_key = search_attribute_key("ajEnqueuedAt", :TIME)

        assert_kind_of Time, attributes[aj_enqueued_at_key]
        assert_equal timestamp, attributes[aj_enqueued_at_key]
      end

      it "omits ajTenantId when no tenant context exists" do
        aj_tenant_id_key = search_attribute_key("ajTenantId", :INTEGER)

        assert_nil attributes[aj_tenant_id_key]
      end

      it "omits ajTags when no tags are configured" do
        aj_tags_key = search_attribute_key("ajTags", :KEYWORD_LIST)

        assert_nil attributes[aj_tags_key]
      end

      it "reuses core search attribute keys across calls" do
        reset_search_attribute_key_cache
        keyword_type = Temporalio::SearchAttributes::IndexedValueType::KEYWORD
        time_type = Temporalio::SearchAttributes::IndexedValueType::TIME
        key_calls = record_search_attribute_key_construction

        described_class.for(job)
        described_class.for(job)

        assert_key_constructed_once key_calls, "ajClass", keyword_type
        assert_key_constructed_once key_calls, "ajQueue", keyword_type
        assert_key_constructed_once key_calls, "ajJobId", keyword_type
        assert_key_constructed_once key_calls, "ajEnqueuedAt", time_type
      end

      it "reuses optional search attribute keys across calls" do
        reset_search_attribute_key_cache
        tagged_tenant_job = SimpleJob.new([TenantContext.new(456)])
        tagged_tenant_job.job_id = "job-optional"
        tagged_tenant_job.queue_name = "billing"
        tagged_tenant_job.define_singleton_method(:temporal_tags) { %w[urgent customer_123] }
        integer_type = Temporalio::SearchAttributes::IndexedValueType::INTEGER
        keyword_list_type = Temporalio::SearchAttributes::IndexedValueType::KEYWORD_LIST
        key_calls = record_search_attribute_key_construction

        described_class.for(tagged_tenant_job)
        described_class.for(tagged_tenant_job)

        assert_key_constructed_once key_calls, "ajTenantId", integer_type
        assert_key_constructed_once key_calls, "ajTags", keyword_list_type
      end
    end

    describe "when queue name is not set" do
      let(:job) { SimpleJob.new }

      before do
        job.job_id = "job-456"
        job.queue_name = nil
      end

      it "falls back to the default queue" do
        aj_queue_key = search_attribute_key("ajQueue", :KEYWORD)

        assert_equal "default", attributes[aj_queue_key]
      end
    end

    describe "when job has a tenant-aware argument" do
      let(:tenant_context) { TenantContext.new(456) }
      let(:job) { SimpleJob.new([tenant_context]) }

      before do
        job.job_id = "job-789"
        job.queue_name = "multitenant"
      end

      it "includes ajTenantId" do
        aj_tenant_id_key = search_attribute_key("ajTenantId", :INTEGER)

        assert_equal 456, attributes[aj_tenant_id_key]
      end
    end

    describe "when the first argument does not respond to tenant_id" do
      let(:job) { SimpleJob.new([Object.new]) }

      before do
        job.job_id = "job-999"
        job.queue_name = "ops"
      end

      it "does not include ajTenantId" do
        aj_tenant_id_key = search_attribute_key("ajTenantId", :INTEGER)

        assert_nil attributes[aj_tenant_id_key]
      end
    end

    describe "when arguments are nil" do
      let(:job) { SimpleJob.new(nil) }

      before do
        job.job_id = "job-555"
        job.queue_name = "ops"
      end

      it "handles nil arguments without raising and omits ajTenantId" do
        aj_tenant_id_key = search_attribute_key("ajTenantId", :INTEGER)

        assert_nil attributes[aj_tenant_id_key]
      end
    end

    describe "when job has tags" do
      let(:job) { SimpleJob.new(["arg"]) }

      before do
        job.job_id = "job-tagged"
        job.queue_name = "billing"
        job.define_singleton_method(:temporal_tags) { %w[urgent customer_123] }
      end

      it "includes ajTags as a keyword list" do
        aj_tags_key = search_attribute_key("ajTags", :KEYWORD_LIST)

        assert_equal %w[urgent customer_123], attributes[aj_tags_key]
      end
    end
  end

  def reset_search_attribute_key_cache
    return unless described_class.instance_variable_defined?(:@search_attribute_keys)

    described_class.remove_instance_variable(:@search_attribute_keys)
  end

  def search_attribute_key(name, type)
    Temporalio::SearchAttributes::Key.new(
      name,
      Temporalio::SearchAttributes::IndexedValueType.const_get(type)
    )
  end

  def record_search_attribute_key_construction
    original_constructor = Temporalio::SearchAttributes::Key.method(:new)

    call_recorded_method(Temporalio::SearchAttributes::Key, :new) do |*arguments|
      original_constructor.call(*arguments)
    end
  end

  def assert_key_constructed_once(key_calls, name, type)
    count = key_calls.calls_for(:new).count do |call|
      call.arguments == [name, type]
    end

    assert_equal 1, count
  end
end
