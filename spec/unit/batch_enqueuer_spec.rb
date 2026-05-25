# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::BatchEnqueuer do
  let(:enqueued_jobs) { [] }
  let(:enqueuer) do
    described_class.new(
      enqueue: lambda do |job, scheduled_at:|
        enqueued_jobs << { job: job, scheduled_at: scheduled_at }
        "handle-#{job.job_id}"
      end,
      validate_job: ->(_job) {},
      validate_scheduled_at: ->(scheduled_at) { scheduled_at }
    )
  end

  it "accepts enumerable inputs without converting them more than once" do
    jobs = Array.new(3) { |index| fake_job("job-#{index}") }
    enumerable = enumerable_for(jobs)

    result = enqueuer.enqueue(enumerable, concurrency: 2)

    expect(result.success_count).to eq(3)
    expect(result.results.map(&:index)).to eq([0, 1, 2])
    expect(enumerable.each_count).to eq(1)
  end

  it "rejects oversized inputs from size hints without iterating" do
    items = sized_without_each(described_class::MAX_BATCH_SIZE + 1)

    expect do
      enqueuer.enqueue(items)
    end.to raise_error(ArgumentError, /at most #{described_class::MAX_BATCH_SIZE}/)

    expect(items.each_called).to be(false)
  end

  it "stops traversing unsized enumerables after the batch size limit is exceeded" do
    items = infinite_jobs(fake_job("streamed-job"))

    expect do
      enqueuer.enqueue(items)
    end.to raise_error(ArgumentError, /at most #{described_class::MAX_BATCH_SIZE}/)

    expect(items.yield_count).to eq(described_class::MAX_BATCH_SIZE + 1)
  end

  it "keeps per-item failure reporting bounded by the accepted batch size" do
    failing_enqueuer = described_class.new(
      enqueue: lambda do |job, scheduled_at:|
        raise "failed #{job.job_id}" if job.job_id == "job-1"

        enqueued_jobs << { job: job, scheduled_at: scheduled_at }
        "handle-#{job.job_id}"
      end,
      validate_job: ->(_job) {},
      validate_scheduled_at: ->(scheduled_at) { scheduled_at }
    )
    jobs = Array.new(3) { |index| fake_job("job-#{index}") }

    result = failing_enqueuer.enqueue(jobs)

    expect(result.success?).to be(false)
    expect(result.success_count).to eq(2)
    expect(result.failure_count).to eq(1)
    expect(result.failures.first.index).to eq(1)
    expect(result.results.length).to eq(3)
  end

  def fake_job(job_id)
    Struct.new(:job_id, :queue_name).new(job_id, "default")
  end

  def enumerable_for(jobs)
    Class.new do
      include Enumerable

      attr_reader :each_count

      define_method(:initialize) do |source_jobs|
        @source_jobs = source_jobs
        @each_count = 0
      end

      define_method(:each) do |&block|
        @each_count += 1
        @source_jobs.each(&block)
      end
    end.new(jobs)
  end

  def sized_without_each(size)
    Class.new do
      attr_reader :each_called

      define_method(:initialize) do |reported_size|
        @reported_size = reported_size
        @each_called = false
      end

      define_method(:size) do
        @reported_size
      end

      define_method(:each) do
        @each_called = true
        raise "should not iterate"
      end
    end.new(size)
  end

  def infinite_jobs(job)
    Class.new do
      include Enumerable

      attr_reader :yield_count

      define_method(:initialize) do |source_job|
        @source_job = source_job
        @yield_count = 0
      end

      define_method(:each) do |&block|
        next enum_for(:each) unless block

        loop do
          @yield_count += 1
          block.call(@source_job)
        end
      end

      def size = nil
    end.new(job)
  end
end
