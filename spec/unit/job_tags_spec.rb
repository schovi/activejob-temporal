# frozen_string_literal: true

require "spec_helper"
require "active_job"

describe ActiveJob::Temporal::JobTags do
  let(:queue_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
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
    ActiveJob::Base.queue_adapter = queue_adapter

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "is prepended into ActiveJob::Base" do
    assert_includes ActiveJob::Base.ancestors, described_class
  end

  it "stores string tags configured on a job instance" do
    job = job_class.new

    job.set(tags: %w[urgent customer_123])

    assert_equal %w[urgent customer_123], job.temporal_tags
  end

  it "normalizes symbol tags to strings" do
    job = job_class.new

    job.set(tags: %i[urgent customer])

    assert_equal %w[urgent customer], job.temporal_tags
  end

  it "preserves tags from configured jobs" do
    job = job_class.set(tags: %w[urgent]).perform_later("payload")

    assert_equal ["urgent"], job.temporal_tags
    assert_equal 1, queue_adapter.enqueued_jobs.size
  end

  it "forwards standard ActiveJob set options" do
    scheduled_at = 5.minutes.from_now

    job = job_class.set(queue: "critical", wait_until: scheduled_at, priority: 7, tags: %w[urgent])
                   .perform_later("payload")

    assert_equal ["urgent"], job.temporal_tags
    assert_equal "critical", queue_adapter.enqueued_jobs.first[:queue]
    assert_in_delta scheduled_at.to_f, queue_adapter.enqueued_jobs.first[:at], 0.001
    assert_equal 7, queue_adapter.enqueued_jobs.first[:priority]
  end

  it "deduplicates tags after normalization" do
    job = job_class.new

    job.set(tags: [:urgent, "urgent"])

    assert_equal ["urgent"], job.temporal_tags
  end

  it "treats nil tags as empty" do
    job = job_class.new

    job.set(tags: nil)

    assert_empty job.temporal_tags
  end

  it "rejects a non-array tag value" do
    job = job_class.new

    error = assert_raises(ArgumentError) { job.set(tags: "urgent") }
    assert_match(/tags must be an Array/, error.message)
  end

  it "rejects unsupported tag members" do
    job = job_class.new

    error = assert_raises(ArgumentError) { job.set(tags: ["urgent", 123]) }
    assert_match(/tags must contain only Strings or Symbols/, error.message)
  end
end
