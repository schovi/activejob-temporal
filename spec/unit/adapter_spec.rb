# frozen_string_literal: true

require "spec_helper"
require "active_job/continuation"
require_relative "../fixtures/sample_jobs"

module AdapterSpecSupport
  class FakeTemporalClient
    attr_accessor :start_workflow_result, :start_workflow_error, :on_start_workflow
    attr_reader :start_workflow_calls

    def initialize(start_workflow_result: "workflow-handle")
      @start_workflow_result = start_workflow_result
      @start_workflow_calls = []
    end

    def start_workflow(*arguments, **keywords)
      @start_workflow_calls << { arguments: arguments, keywords: keywords }
      raise start_workflow_error if start_workflow_error

      return on_start_workflow.call(*arguments, **keywords) if on_start_workflow

      start_workflow_result
    end
  end
end

describe ActiveJob::Temporal::Adapter do
  describe ".build_workflow_id" do
    let(:configuration) { ActiveJob::Temporal::Configuration.new }

    before do
      call_recorded_method(ActiveJob::Temporal, :config, returns: configuration)
    end

    describe "with a simple job" do
      let(:job) do
        job = SimpleJob.new
        job.job_id = "abc-123"
        job
      end

      it "returns workflow ID in the expected format" do
        workflow_id = described_class.build_workflow_id(job)

        assert_equal "ajwf:SimpleJob:abc-123", workflow_id
      end

      it "is deterministic for the same job instance" do
        first = described_class.build_workflow_id(job)
        second = described_class.build_workflow_id(job)

        assert_equal first, second
      end
    end

    describe "with different job classes sharing job_id" do
      let(:simple_job) do
        job = SimpleJob.new
        job.job_id = "shared-id"
        job
      end

      let(:scheduled_job) do
        job = ScheduledJob.new
        job.job_id = "shared-id"
        job
      end

      it "produces different workflow IDs" do
        simple_id = described_class.build_workflow_id(simple_job)
        scheduled_id = described_class.build_workflow_id(scheduled_job)

        assert_equal "ajwf:SimpleJob:shared-id", simple_id
        assert_equal "ajwf:ScheduledJob:shared-id", scheduled_id
        refute_equal simple_id, scheduled_id
      end
    end

    describe "with the same job class and different job IDs" do
      it "returns unique workflow IDs" do
        job_one = SimpleJob.new
        job_one.job_id = "id-1"

        job_two = SimpleJob.new
        job_two.job_id = "id-2"

        id_one = described_class.build_workflow_id(job_one)
        id_two = described_class.build_workflow_id(job_two)

        assert_equal "ajwf:SimpleJob:id-1", id_one
        assert_equal "ajwf:SimpleJob:id-2", id_two
        refute_equal id_one, id_two
      end
    end

    describe "with a custom workflow ID generator configured" do
      it "returns the configured workflow ID" do
        configuration.workflow_id_generator = ->(job) { "custom:#{job.class.name}:#{job.job_id}" }
        job = SimpleJob.new
        job.job_id = "custom-id"

        assert_equal "custom:SimpleJob:custom-id", described_class.build_workflow_id(job)
      end
    end
  end

  describe ".resolve_task_queue" do
    let(:configuration) { ActiveJob::Temporal::Configuration.new }
    let(:job) { SimpleJob.new }

    before do
      call_recorded_method(ActiveJob::Temporal, :config, returns: configuration)
    end

    describe "when no prefix is configured" do
      before do
        configuration.task_queue_prefix = nil
      end

      it "returns the job queue name" do
        job.queue_name = "billing"

        assert_equal "billing", described_class.resolve_task_queue(job)
      end

      it "falls back to the default queue when queue_name is nil" do
        job.queue_name = nil

        assert_equal "default", described_class.resolve_task_queue(job)
      end

      it "treats blank queue names as default" do
        job.queue_name = "   "

        assert_equal "default", described_class.resolve_task_queue(job)
      end
    end

    describe "when a prefix is configured" do
      before do
        configuration.task_queue_prefix = "prod-"
      end

      it "prepends the prefix to the queue name" do
        job.queue_name = "billing"

        assert_equal "prod-billing", described_class.resolve_task_queue(job)
      end

      it "prepends the prefix to the default queue" do
        job.queue_name = nil

        assert_equal "prod-default", described_class.resolve_task_queue(job)
      end

      it "works for other queue names" do
        job.queue_name = "mailers"

        assert_equal "prod-mailers", described_class.resolve_task_queue(job)
      end
    end

    describe "when the prefix is an empty string" do
      before do
        configuration.task_queue_prefix = ""
      end

      it "treats an empty prefix as absent" do
        job.queue_name = "exports"

        assert_equal "exports", described_class.resolve_task_queue(job)
      end
    end

    describe "when priority task queues are not configured" do
      it "does not evaluate dynamic job priorities" do
        job.queue_name = "mailers"
        job.define_singleton_method(:priority) { raise "priority evaluated" }

        assert_equal "mailers", described_class.resolve_task_queue(job)
      end
    end

    describe "when priority task queues are configured" do
      before do
        configuration.priority_task_queues = {
          10 => "high_priority",
          90 => "low_priority"
        }
      end

      it "routes numeric priorities to the configured task queue" do
        job.queue_name = "default"
        job.define_singleton_method(:priority) { 10 }

        assert_equal "high_priority", described_class.resolve_task_queue(job)
      end

      it "routes priorities assigned through ActiveJob set" do
        priority_job_class = Class.new(ActiveJob::Base) do
          self.queue_adapter = :test

          def self.name = "PriorityRoutingJob"

          def perform; end
        end
        job = priority_job_class.set(priority: 10).perform_later
        job.queue_name = "default"

        assert_equal "high_priority", described_class.resolve_task_queue(job)
      end

      it "routes other numeric priorities to the configured task queue" do
        job.queue_name = "default"
        job.define_singleton_method(:priority) { 90 }

        assert_equal "low_priority", described_class.resolve_task_queue(job)
      end

      it "falls back to the job queue when priority is unmapped" do
        job.queue_name = "mailers"
        job.define_singleton_method(:priority) { 50 }

        assert_equal "mailers", described_class.resolve_task_queue(job)
      end

      it "falls back to the job queue when priority is not an integer" do
        job.queue_name = "mailers"
        job.define_singleton_method(:priority) { "10" }

        assert_equal "mailers", described_class.resolve_task_queue(job)
      end

      it "applies task queue prefixes to priority task queues" do
        configuration.task_queue_prefix = "prod-"
        job.queue_name = "default"
        job.define_singleton_method(:priority) { 10 }

        assert_equal "prod-high_priority", described_class.resolve_task_queue(job)
      end
    end
  end
end

describe ActiveJob::QueueAdapters::TemporalAdapter do
  let(:job) do
    job = SimpleJob.new
    job.job_id = "job-123"
    job.queue_name = "mailers"
    job
  end

  let(:client) { AdapterSpecSupport::FakeTemporalClient.new }
  let(:config) { build_configuration }

  before do
    call_recorded_method(ActiveJob::Temporal, :client, returns: client)
    call_recorded_method(ActiveJob::Temporal, :config, returns: config)
    call_recorded_method(ActiveJob::Temporal::Logger, :log_event)
  end

  let(:adapter) { described_class.new }

  describe "#initialize" do
    it "creates a WorkflowEnqueuer instance" do
      assert_instance_of ActiveJob::Temporal::WorkflowEnqueuer, adapter.enqueuer
    end

    it "inherits the Rails queue adapter contract" do
      assert_kind_of ActiveJob::QueueAdapters::AbstractAdapter, adapter
    end
  end

  describe "#stopping?" do
    it "defaults to false" do
      assert_equal false, adapter.stopping?
    end

    it "returns true after the adapter is marked as stopping" do
      adapter.stopping = true

      assert_equal true, adapter.stopping?
    end
  end

  describe "Rails 8 continuable checkpoint compatibility" do
    it "interrupts continuable jobs when the adapter is stopping" do
      continuable_job_class = Class.new(ActiveJob::Base) do
        include ActiveJob::Continuable

        def self.name = "ContinuableStoppingJob"

        def perform; end
      end
      continuable_job = continuable_job_class.new

      call_recorded_method(continuable_job, :queue_adapter, returns: adapter)
      adapter.stopping = true

      error = assert_raises(ActiveJob::Continuation::Interrupt) { continuable_job.checkpoint! }

      assert_match(/stopping/, error.message)
    end
  end

  describe "#enqueue" do
    it "delegates to the enqueuer" do
      result = adapter.enqueue(job)

      assert_equal 1, client.start_workflow_calls.size
      assert_equal "workflow-handle", result
    end

    it "uses the current Temporal client when enqueueing" do
      first_client = AdapterSpecSupport::FakeTemporalClient.new(start_workflow_result: "first-handle")
      second_client = AdapterSpecSupport::FakeTemporalClient.new(start_workflow_result: "second-handle")
      first_job = job
      second_job = ScheduledJob.new
      clients = [first_client, second_client]

      call_recorded_method(ActiveJob::Temporal, :client) { clients.shift }

      assert_equal "first-handle", adapter.enqueue(first_job)
      assert_equal "second-handle", adapter.enqueue(second_job)
      assert_equal 1, first_client.start_workflow_calls.size
      assert_equal 1, second_client.start_workflow_calls.size
    end

    it "propagates enqueuer errors" do
      client.start_workflow_error = StandardError.new("workflow failed")

      assert_raises(ActiveJob::EnqueueError) { adapter.enqueue(job) }
    end

    it "raises a duplicate enqueue error for duplicate workflows" do
      error = Class.new(StandardError)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", error)
      client.start_workflow_error = error.new("already started")

      assert_raises(ActiveJob::Temporal::DuplicateEnqueueError) { adapter.enqueue(job) }
    end
  end

  describe "#enqueue_at" do
    let(:timestamp) { (Time.now + 300).to_i }
    let(:scheduled_time) { Time.at(timestamp) }

    it "converts timestamp to Time and enqueues with scheduled_at" do
      time_at_calls = call_recorded_method(Time, :at, returns: scheduled_time)

      adapter.enqueue_at(job, timestamp)

      assert_equal [[timestamp]], time_at_calls.calls_for(:at).map(&:arguments)
      assert_equal 1, client.start_workflow_calls.size
    end

    it "returns workflow handle for scheduled jobs" do
      call_recorded_method(Time, :at, returns: scheduled_time)

      result = adapter.enqueue_at(job, timestamp)

      assert_equal "workflow-handle", result
    end

    it "raises a duplicate enqueue error for duplicate scheduled workflows" do
      error = Class.new(StandardError)
      stub_const("Temporalio::Client::WorkflowAlreadyStartedError", error)
      client.start_workflow_error = error.new("already started")
      call_recorded_method(Time, :at, returns: scheduled_time)

      assert_raises(ActiveJob::Temporal::DuplicateEnqueueError) { adapter.enqueue_at(job, timestamp) }
    end

    it "treats past timestamps as immediate" do
      now = Time.utc(2026, 5, 25, 12, 0, 0)
      past_timestamp = now.to_i - 60
      call_recorded_method(Time, :now, returns: now)
      call_recorded_method(Time, :at, returns: now - 60)
      client.on_start_workflow = lambda do |_workflow_class, payload, **_options|
        assert_nil payload[:scheduled_at]
        "workflow-handle"
      end

      result = adapter.enqueue_at(job, past_timestamp)

      assert_equal "workflow-handle", result
    end
  end

  describe "#enqueue_after_transaction_commit?" do
    it "returns true for legacy adapter transaction contracts" do
      assert_equal true, adapter.enqueue_after_transaction_commit?
    end
  end
end

describe "Temporal duplicate enqueue handling through ActiveJob" do
  let(:client) { AdapterSpecSupport::FakeTemporalClient.new }
  let(:config) { build_configuration }
  let(:duplicate_error) { Class.new(StandardError) }

  before do
    stub_const("Temporalio::Client::WorkflowAlreadyStartedError", duplicate_error)
    call_recorded_method(ActiveJob::Temporal, :client, returns: client)
    call_recorded_method(ActiveJob::Temporal, :config, returns: config)
    client.start_workflow_error = duplicate_error.new("already started")
    call_recorded_method(ActiveJob::Temporal::Logger, :log_event)
  end

  it "returns false and exposes a duplicate enqueue error to perform_later callers" do
    job_class = stub_const("DuplicatePerformLaterJob", Class.new(ActiveJob::Base) do
      self.queue_adapter = :temporal

      def perform; end
    end)
    enqueued_job = nil

    result = job_class.perform_later { |job| enqueued_job = job }

    assert_equal false, result
    assert_equal false, enqueued_job.successfully_enqueued?
    assert_instance_of ActiveJob::Temporal::DuplicateEnqueueError, enqueued_job.enqueue_error
    assert_includes enqueued_job.enqueue_error.message, "already enqueued"
  end
end

describe "ActiveJob adapter registration" do
  describe ".lookup" do
    it "returns the Temporal adapter when requested by symbol" do
      adapter_class = ActiveJob::QueueAdapters.lookup(:temporal)

      assert_equal ActiveJob::QueueAdapters::TemporalAdapter, adapter_class
    end
  end
end

def build_configuration
  config = ActiveJob::Temporal::Configuration.new
  config.target = "localhost:7233"
  config.namespace = "default"
  config.task_queue_prefix = nil
  config
end
