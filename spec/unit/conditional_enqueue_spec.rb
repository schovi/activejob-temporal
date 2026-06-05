# frozen_string_literal: true

require "spec_helper"
require "active_job"

describe ActiveJob::Temporal::ConditionalEnqueue do
  let(:queue_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
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
    ActiveJob::Base.queue_adapter = queue_adapter

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "is included in ActiveJob::Base" do
    assert_includes ActiveJob::Base.included_modules, described_class
  end

  it "enqueues when a callable condition returns true" do
    seen_arguments = nil
    condition = lambda do |arguments|
      seen_arguments = arguments
      true
    end

    job = job_class.perform_later_if(condition, :allowed, "payload")

    assert_instance_of job_class, job
    assert_equal [:allowed, "payload"], seen_arguments
    assert_equal 1, queue_adapter.enqueued_jobs.size
  end

  it "returns nil without enqueueing when a callable condition returns false" do
    condition = ->(_arguments) { false }

    assert_nil job_class.perform_later_if(condition, :blocked)
    assert_empty queue_adapter.enqueued_jobs
  end

  it "enqueues when a symbol condition returns true" do
    job = job_class.perform_later_if(:should_enqueue?, :allowed)

    assert_instance_of job_class, job
    assert_equal 1, queue_adapter.enqueued_jobs.size
  end

  it "returns nil without enqueueing when a symbol condition returns false" do
    assert_nil job_class.perform_later_if(:should_enqueue?, :blocked)
    assert_empty queue_adapter.enqueued_jobs
  end

  it "enqueues when a string condition returns true" do
    job = job_class.perform_later_if("should_enqueue?", :allowed)

    assert_instance_of job_class, job
    assert_equal 1, queue_adapter.enqueued_jobs.size
  end

  it "supports configured jobs from set" do
    logger_warnings = call_recorded_method(ActiveJob::Temporal::Logger, :warn)

    job = job_class.set(queue: "critical").perform_later_if(:should_enqueue?, :allowed)

    assert_instance_of job_class, job
    assert_equal 1, queue_adapter.enqueued_jobs.size
    assert_equal "critical", queue_adapter.enqueued_jobs.first[:queue]
    assert_private_api_warning logger_warnings
  end

  it "returns nil for configured jobs when the condition returns false" do
    call_recorded_method(ActiveJob::Temporal::Logger, :warn)

    assert_nil job_class.set(queue: "critical").perform_later_if(:should_enqueue?, :blocked)
    assert_empty queue_adapter.enqueued_jobs
  end

  it "fails clearly when configured job internals are unsupported" do
    configured_job = ActiveJob::ConfiguredJob.allocate

    error = assert_raises(ArgumentError) { configured_job.perform_later_if(:should_enqueue?, :allowed) }
    assert_match(/ActiveJob::ConfiguredJob internals changed for conditional_enqueue.*@job_class/, error.message)
  end

  it "passes keyword arguments to the condition as job arguments" do
    seen_arguments = nil
    condition = lambda do |arguments|
      seen_arguments = arguments
      true
    end

    job_class.perform_later_if(condition, :allowed, count: 2)

    assert_equal [:allowed, { count: 2 }], seen_arguments
  end

  it "rejects unsupported conditions" do
    error = assert_raises(ArgumentError) { job_class.perform_later_if(true, :allowed) }
    assert_match(/condition must be a Symbol, String, or respond to #call/, error.message)
  end

  it "lets condition exceptions bubble" do
    error = RuntimeError.new("condition failed")
    condition = ->(_arguments) { raise error }

    raised_error = assert_raises(RuntimeError) { job_class.perform_later_if(condition, :allowed) }
    assert_same error, raised_error
    assert_empty queue_adapter.enqueued_jobs
  end

  def assert_private_api_warning(logger_warnings)
    warning = logger_warnings.calls_for(:warn).find do |call|
      call.arguments == ["active_job_configured_job_private_api"] &&
        call.keywords[:feature] == "conditional_enqueue"
    end

    refute_nil warning
  end
end
