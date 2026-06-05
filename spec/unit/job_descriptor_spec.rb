# frozen_string_literal: true

require "spec_helper"
require "active_job"

describe ActiveJob::Temporal::JobDescriptor do
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "DescriptorJob"

      def perform(*) = nil
    end
  end

  it "normalizes to the nested job payload shape" do
    descriptor = described_class.new(job_class, queue: "critical", priority: 7)
    expected_payload = {
      job_class: "DescriptorJob",
      options: {
        queue: "critical",
        priority: 7
      }
    }

    assert_equal expected_payload, descriptor.to_h
  end

  it "duplicates option hashes for callers" do
    options = { queue: "critical" }
    descriptor = described_class.new(job_class, options)
    options[:queue] = "changed"

    assert_equal({ queue: "critical" }, descriptor.to_h[:options])
    refute_same descriptor.options, descriptor.to_h[:options]
  end

  it "is exposed through ActiveJob::Temporal.job" do
    descriptor = ActiveJob::Temporal.job(job_class, queue: "critical")
    expected_payload = {
      job_class: "DescriptorJob",
      options: {
        queue: "critical"
      }
    }

    assert_instance_of described_class, descriptor
    assert_equal expected_payload, descriptor.to_h
  end

  it "rejects anonymous ActiveJob classes" do
    anonymous_job = Class.new(ActiveJob::Base)

    error = assert_raises(ArgumentError) { described_class.new(anonymous_job) }
    assert_match(/named ActiveJob class/, error.message)
  end

  it "rejects non-ActiveJob classes" do
    error = assert_raises(ArgumentError) { described_class.new(Object) }
    assert_match(/named ActiveJob class/, error.message)
  end
end
