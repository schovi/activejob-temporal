# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe "ActiveJob::ConfiguredJob compatibility contract" do
  let(:test_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
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
    ActiveJob::Base.queue_adapter = test_adapter

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  before do
    allow(ActiveJob::Temporal::Logger).to receive(:warn)
  end

  it "captures configured jobs in chain entries" do
    job = root_job_class
          .set(chain: [next_job_class.set(queue: "critical", priority: 7)])
          .perform_later(:allowed)

    expect(job.temporal_chain).to eq([
                                       {
                                         job_class: "ConfiguredContractNextJob",
                                         options: {
                                           queue: "critical",
                                           priority: 7
                                         }
                                       }
                                     ])
  end

  it "captures configured jobs in child workflow entries" do
    job = root_job_class
          .set(child_workflows: [next_job_class.set(queue: "critical", priority: 7, tags: %i[fanout])])
          .perform_later(:allowed)

    expect(job.temporal_child_workflows).to eq([
                                                 {
                                                   job_class: "ConfiguredContractNextJob",
                                                   options: {
                                                     queue: "critical",
                                                     priority: 7,
                                                     tags: %w[fanout]
                                                   }
                                                 }
                                               ])
  end

  it "runs conditional enqueue helpers on configured jobs" do
    job = root_job_class.set(queue: "critical").perform_later_if(:should_enqueue?, :allowed)

    expect(job).to be_a(root_job_class)
    expect(test_adapter.enqueued_jobs.first[:queue]).to eq("critical")
  end
end
