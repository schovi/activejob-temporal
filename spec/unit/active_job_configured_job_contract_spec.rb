# frozen_string_literal: true

require "spec_helper"
require "active_job"

describe "ActiveJob::ConfiguredJob compatibility contract" do
  let(:queue_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
  let(:root_job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "ConfiguredContractRootJob"

      def self.should_enqueue?(arguments)
        arguments.first == :allowed
      end

      def perform(*) = nil
    end
  end
  let(:next_job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "ConfiguredContractNextJob"

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

  before do
    call_recorded_method(ActiveJob::Temporal::Logger, :warn)
  end

  it "captures configured jobs in chain entries" do
    job = root_job_class
          .set(chain: [next_job_class.set(queue: "critical", priority: 7)])
          .perform_later(:allowed)
    expected_chain = [
      {
        job_class: "ConfiguredContractNextJob",
        options: {
          queue: "critical",
          priority: 7
        }
      }
    ]

    assert_equal expected_chain, job.temporal_chain
  end

  it "captures configured jobs in child workflow entries" do
    job = root_job_class
          .set(child_workflows: [next_job_class.set(queue: "critical", priority: 7, tags: %i[fanout])])
          .perform_later(:allowed)
    expected_child_workflows = [
      {
        job_class: "ConfiguredContractNextJob",
        options: {
          queue: "critical",
          priority: 7,
          tags: %w[fanout]
        }
      }
    ]

    assert_equal expected_child_workflows, job.temporal_child_workflows
  end

  it "runs conditional enqueue helpers on configured jobs" do
    job = root_job_class.set(queue: "critical").perform_later_if(:should_enqueue?, :allowed)

    assert_instance_of root_job_class, job
    assert_equal "critical", queue_adapter.enqueued_jobs.first[:queue]
  end
end
