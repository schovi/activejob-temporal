# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe ActiveJob::Temporal::ConditionalEnqueue do
  let(:test_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name
        "ConditionalEnqueueJob"
      end

      def self.should_enqueue?(arguments)
        arguments.first == :allowed
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

  it "is included in ActiveJob::Base" do
    expect(ActiveJob::Base.included_modules).to include(described_class)
  end

  it "enqueues when a callable condition returns true" do
    seen_arguments = nil
    condition = lambda do |arguments|
      seen_arguments = arguments
      true
    end

    job = job_class.perform_later_if(condition, :allowed, "payload")

    expect(job).to be_a(job_class)
    expect(seen_arguments).to eq([:allowed, "payload"])
    expect(test_adapter.enqueued_jobs.size).to eq(1)
  end

  it "returns nil without enqueueing when a callable condition returns false" do
    condition = ->(_arguments) { false }

    expect(job_class.perform_later_if(condition, :blocked)).to be_nil
    expect(test_adapter.enqueued_jobs).to be_empty
  end

  it "enqueues when a symbol condition returns true" do
    job = job_class.perform_later_if(:should_enqueue?, :allowed)

    expect(job).to be_a(job_class)
    expect(test_adapter.enqueued_jobs.size).to eq(1)
  end

  it "returns nil without enqueueing when a symbol condition returns false" do
    expect(job_class.perform_later_if(:should_enqueue?, :blocked)).to be_nil
    expect(test_adapter.enqueued_jobs).to be_empty
  end

  it "enqueues when a string condition returns true" do
    job = job_class.perform_later_if("should_enqueue?", :allowed)

    expect(job).to be_a(job_class)
    expect(test_adapter.enqueued_jobs.size).to eq(1)
  end

  it "supports configured jobs from set" do
    allow(ActiveJob::Temporal::Logger).to receive(:warn)

    job = job_class.set(queue: "critical").perform_later_if(:should_enqueue?, :allowed)

    expect(job).to be_a(job_class)
    expect(test_adapter.enqueued_jobs.size).to eq(1)
    expect(test_adapter.enqueued_jobs.first[:queue]).to eq("critical")
    expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
      "active_job_configured_job_private_api",
      hash_including(feature: "conditional_enqueue")
    )
  end

  it "returns nil for configured jobs when the condition returns false" do
    allow(ActiveJob::Temporal::Logger).to receive(:warn)

    expect(job_class.set(queue: "critical").perform_later_if(:should_enqueue?, :blocked)).to be_nil
    expect(test_adapter.enqueued_jobs).to be_empty
  end

  it "fails clearly when configured job internals are unsupported" do
    configured_job = ActiveJob::ConfiguredJob.allocate

    expect { configured_job.perform_later_if(:should_enqueue?, :allowed) }
      .to raise_error(
        ArgumentError,
        /ActiveJob::ConfiguredJob internals changed for conditional_enqueue.*@job_class/
      )
  end

  it "passes keyword arguments to the condition as job arguments" do
    seen_arguments = nil
    condition = lambda do |arguments|
      seen_arguments = arguments
      true
    end

    job_class.perform_later_if(condition, :allowed, count: 2)

    expect(seen_arguments).to eq([:allowed, { count: 2 }])
  end

  it "rejects unsupported conditions" do
    expect { job_class.perform_later_if(true, :allowed) }
      .to raise_error(ArgumentError, /condition must be a Symbol, String, or respond to #call/)
  end

  it "lets condition exceptions bubble" do
    error = RuntimeError.new("condition failed")
    condition = ->(_arguments) { raise error }

    expect { job_class.perform_later_if(condition, :allowed) }.to raise_error(error)
    expect(test_adapter.enqueued_jobs).to be_empty
  end
end
