# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe ActiveJob::Temporal::JobTags do
  let(:test_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name
        "TaggedJob"
      end

      def perform(*) = nil
    end
  end

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = test_adapter

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "is prepended into ActiveJob::Base" do
    expect(ActiveJob::Base.ancestors).to include(described_class)
  end

  it "stores string tags configured on a job instance" do
    job = job_class.new

    job.set(tags: %w[urgent customer_123])

    expect(job.temporal_tags).to eq(%w[urgent customer_123])
  end

  it "normalizes symbol tags to strings" do
    job = job_class.new

    job.set(tags: %i[urgent customer])

    expect(job.temporal_tags).to eq(%w[urgent customer])
  end

  it "preserves tags from configured jobs" do
    job = job_class.set(tags: %w[urgent]).perform_later("payload")

    expect(job.temporal_tags).to eq(["urgent"])
    expect(test_adapter.enqueued_jobs.size).to eq(1)
  end

  it "forwards standard ActiveJob set options" do
    scheduled_at = 5.minutes.from_now

    job = job_class.set(queue: "critical", wait_until: scheduled_at, priority: 7, tags: %w[urgent])
                   .perform_later("payload")

    expect(job.temporal_tags).to eq(["urgent"])
    expect(test_adapter.enqueued_jobs.first[:queue]).to eq("critical")
    expect(test_adapter.enqueued_jobs.first[:at]).to be_within(0.001).of(scheduled_at.to_f)
    expect(test_adapter.enqueued_jobs.first[:priority]).to eq(7)
  end

  it "deduplicates tags after normalization" do
    job = job_class.new

    job.set(tags: [:urgent, "urgent"])

    expect(job.temporal_tags).to eq(["urgent"])
  end

  it "treats nil tags as empty" do
    job = job_class.new

    job.set(tags: nil)

    expect(job.temporal_tags).to eq([])
  end

  it "rejects a non-array tag value" do
    job = job_class.new

    expect { job.set(tags: "urgent") }
      .to raise_error(ArgumentError, /tags must be an Array/)
  end

  it "rejects unsupported tag members" do
    job = job_class.new

    expect { job.set(tags: ["urgent", 123]) }
      .to raise_error(ArgumentError, /tags must contain only Strings or Symbols/)
  end
end
