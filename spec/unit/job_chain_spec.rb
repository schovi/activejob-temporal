# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe "ActiveJob Temporal job chaining" do
  let(:test_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "ChainRootJob"

      def perform(*) = nil
    end
  end
  let(:next_job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "ChainNextJob"

      def perform(*) = nil
    end
  end
  let(:final_job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "ChainFinalJob"

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

  it "captures chain steps configured through ActiveJob.set" do
    configured_final_step = final_job_class.set(queue: "reporting", priority: 7)

    job = job_class.set(chain: [next_job_class, configured_final_step]).perform_later("seed")

    expect(job.temporal_chain).to eq([
                                       {
                                         job_class: "ChainNextJob",
                                         options: {}
                                       },
                                       {
                                         job_class: "ChainFinalJob",
                                         options: {
                                           queue: "reporting",
                                           priority: 7
                                         }
                                       }
                                     ])
    expect(test_adapter.enqueued_jobs.size).to eq(1)
  end

  it "captures external Temporal activity and workflow refs in chain order" do
    payment_activity = ActiveJob::Temporal.activity(
      "payments.AuthorizePayment",
      task_queue: "payments-kotlin",
      start_to_close_timeout: 30.seconds
    )
    inventory_workflow = ActiveJob::Temporal.workflow(
      "inventory.ReserveInventoryWorkflow",
      task_queue: "inventory-kotlin",
      run_timeout: 5.minutes
    )

    job = job_class.set(chain: [next_job_class, payment_activity, inventory_workflow]).perform_later("seed")

    expect(job.temporal_chain).to eq([
                                       {
                                         job_class: "ChainNextJob",
                                         options: {}
                                       },
                                       {
                                         temporal_operation: "activity",
                                         temporal_type: "payments.AuthorizePayment",
                                         options: {
                                           task_queue: "payments-kotlin",
                                           start_to_close_timeout: 30.0
                                         }
                                       },
                                       {
                                         temporal_operation: "workflow",
                                         temporal_type: "inventory.ReserveInventoryWorkflow",
                                         options: {
                                           task_queue: "inventory-kotlin",
                                           run_timeout: 300.0
                                         }
                                       }
                                     ])
  end

  it "captures chain steps configured on a job instance" do
    job = job_class.new

    job.set(chain: [next_job_class])

    expect(job.temporal_chain).to eq([
                                       {
                                         job_class: "ChainNextJob",
                                         options: {}
                                       }
                                     ])
  end

  it "rejects a non-array chain value" do
    job = job_class.new

    expect { job.set(chain: next_job_class) }
      .to raise_error(ArgumentError, /chain must be an Array/)
  end

  it "rejects chain entries that are not ActiveJob classes or configured jobs" do
    job = job_class.new

    expect { job.set(chain: [Object.new]) }
      .to raise_error(ArgumentError, /chain entries must be ActiveJob classes or configured jobs/)
  end

  it "rejects configured chain steps with unsupported ActiveJob options" do
    job = job_class.new

    expect { job.set(chain: [next_job_class.set(wait: 5)]) }
      .to raise_error(ArgumentError, /only support queue and priority options/)
  end

  it "rejects external Temporal refs without a task queue" do
    expect { ActiveJob::Temporal.activity("payments.AuthorizePayment") }
      .to raise_error(ArgumentError, /require task_queue/)
  end
end
