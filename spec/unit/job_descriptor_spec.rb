# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe ActiveJob::Temporal::JobDescriptor do
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "DescriptorJob"

      def perform(*) = nil
    end
  end

  it "normalizes to the nested job payload shape" do
    descriptor = described_class.new(job_class, queue: "critical", priority: 7)

    expect(descriptor.to_h).to eq(
      job_class: "DescriptorJob",
      options: {
        queue: "critical",
        priority: 7
      }
    )
  end

  it "duplicates option hashes for callers" do
    options = { queue: "critical" }
    descriptor = described_class.new(job_class, options)
    options[:queue] = "changed"

    expect(descriptor.to_h[:options]).to eq(queue: "critical")
    expect(descriptor.to_h[:options]).not_to equal(descriptor.options)
  end

  it "is exposed through ActiveJob::Temporal.job" do
    descriptor = ActiveJob::Temporal.job(job_class, queue: "critical")

    expect(descriptor).to be_a(described_class)
    expect(descriptor.to_h).to eq(
      job_class: "DescriptorJob",
      options: {
        queue: "critical"
      }
    )
  end

  it "rejects anonymous ActiveJob classes" do
    anonymous_job = Class.new(ActiveJob::Base)

    expect { described_class.new(anonymous_job) }
      .to raise_error(ArgumentError, /named ActiveJob class/)
  end

  it "rejects non-ActiveJob classes" do
    expect { described_class.new(Object) }
      .to raise_error(ArgumentError, /named ActiveJob class/)
  end
end
