# frozen_string_literal: true

require "spec_helper"
require "active_job"

describe "ActiveJob Temporal job chaining" do
  let(:queue_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
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
    ActiveJob::Base.queue_adapter = queue_adapter

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "captures chain steps configured through Temporal job descriptors" do
    configured_final_step = ActiveJob::Temporal.job(final_job_class, queue: "reporting", priority: 7)

    job = job_class.set(chain: [next_job_class, configured_final_step]).perform_later("seed")
    expected_chain = [
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
    ]

    assert_equal expected_chain, job.temporal_chain
    assert_equal 1, queue_adapter.enqueued_jobs.size
  end

  it "supports ActiveJob configured jobs as a warned compatibility fallback" do
    logger_warnings = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
    configured_final_step = final_job_class.set(queue: "reporting", priority: 7)

    job = job_class.set(chain: [configured_final_step]).perform_later("seed")
    expected_chain = [
      {
        job_class: "ChainFinalJob",
        options: {
          queue: "reporting",
          priority: 7
        }
      }
    ]

    assert_equal expected_chain, job.temporal_chain
    assert_private_api_warning logger_warnings, "chain"
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
    expected_chain = [
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
    ]

    assert_equal expected_chain, job.temporal_chain
  end

  it "captures chain steps configured on a job instance" do
    job = job_class.new

    job.set(chain: [next_job_class])
    expected_chain = [
      {
        job_class: "ChainNextJob",
        options: {}
      }
    ]

    assert_equal expected_chain, job.temporal_chain
  end

  it "rejects a non-array chain value" do
    job = job_class.new

    error = assert_raises(ArgumentError) { job.set(chain: next_job_class) }
    assert_match(/chain must be an Array/, error.message)
  end

  it "rejects chain entries that are not ActiveJob classes or configured jobs" do
    job = job_class.new

    error = assert_raises(ArgumentError) { job.set(chain: [Object.new]) }
    assert_match(/chain entries must be ActiveJob classes or configured jobs/, error.message)
  end

  it "rejects configured chain steps with unsupported ActiveJob options" do
    job = job_class.new

    error = assert_raises(ArgumentError) { job.set(chain: [ActiveJob::Temporal.job(next_job_class, wait: 5)]) }
    assert_match(/only support queue and priority options/, error.message)
  end

  it "rejects external Temporal refs without a task queue" do
    error = assert_raises(ArgumentError) { ActiveJob::Temporal.activity("payments.AuthorizePayment") }
    assert_match(/require task_queue/, error.message)
  end

  def assert_private_api_warning(logger_warnings, feature)
    warning = logger_warnings.calls_for(:warn).find do |call|
      call.arguments == ["active_job_configured_job_private_api"] && call.keywords[:feature] == feature
    end

    refute_nil warning
  end
end
