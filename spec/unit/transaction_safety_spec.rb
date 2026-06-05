# frozen_string_literal: true

require "spec_helper"
require "active_job/enqueue_after_transaction_commit"

module TransactionSafetySpecSupport
  class FakeTemporalClient
    attr_reader :start_workflow_calls

    def initialize
      @start_workflow_calls = []
    end

    def start_workflow(*arguments, **keywords)
      start_workflow_calls << [arguments, keywords]
      "workflow-handle"
    end
  end
end

describe "ActiveJob::Temporal transaction safety" do
  let(:client) { TransactionSafetySpecSupport::FakeTemporalClient.new }
  let(:config) { build_configuration }
  let(:fake_active_record) do
    Class.new do
      class << self
        def after_all_transactions_commit(&block)
          callbacks << block
        end

        def commit!
          callbacks.each(&:call)
          reset!
        end

        def rollback!
          reset!
        end

        def reset!
          @callbacks = []
        end

        private

        def callbacks
          @callbacks ||= []
        end
      end
    end
  end

  let(:job_class) do
    stub_const("TransactionSafetyJob", Class.new(ActiveJob::Base) do
      include ActiveJob::EnqueueAfterTransactionCommit

      def perform; end
    end)
  end

  before do
    stub_const("ActiveRecord", fake_active_record)
    fake_active_record.reset!

    call_recorded_method(ActiveJob::Temporal, :client, returns: client)
    call_recorded_method(ActiveJob::Temporal, :config, returns: config)
    call_recorded_method(ActiveJob::Temporal::Logger, :log_event)
  end

  it "enables the Rails transaction commit setting when a job uses the Temporal adapter" do
    assert_equal false, job_class.enqueue_after_transaction_commit

    job_class.queue_adapter = :temporal

    assert_equal true, job_class.enqueue_after_transaction_commit
  end

  it "enables transaction safety when a Temporal adapter instance is assigned" do
    assert_equal false, job_class.enqueue_after_transaction_commit

    job_class.queue_adapter = ActiveJob::QueueAdapters::TemporalAdapter.new

    assert_equal true, job_class.enqueue_after_transaction_commit
  end

  it "restores the previous transaction commit setting when switching away from Temporal" do
    assert_equal false, job_class.enqueue_after_transaction_commit

    job_class.queue_adapter = :temporal
    job_class.queue_adapter = :test

    assert_equal false, job_class.enqueue_after_transaction_commit
  end

  it "restores a previous explicit transaction commit setting when switching away from Temporal" do
    job_class.enqueue_after_transaction_commit = true

    job_class.queue_adapter = :temporal
    job_class.queue_adapter = :test

    assert_equal true, job_class.enqueue_after_transaction_commit
  end

  it "respects an explicit job-level opt-out before selecting the Temporal adapter" do
    job_class.enqueue_after_transaction_commit = false

    job_class.queue_adapter = :temporal

    assert_equal false, job_class.enqueue_after_transaction_commit
  end

  it "respects an explicit job-level opt-out after selecting the Temporal adapter" do
    job_class.queue_adapter = :temporal
    job_class.enqueue_after_transaction_commit = false

    job_class.queue_adapter = :temporal

    assert_equal false, job_class.enqueue_after_transaction_commit
  end

  it "keeps per-job Temporal adapter transaction settings scoped to that job class" do
    sibling_job_class = Class.new(ActiveJob::Base) do
      include ActiveJob::EnqueueAfterTransactionCommit

      def perform; end
    end

    job_class.queue_adapter = :temporal
    sibling_job_class.queue_adapter = :test

    assert_equal true, job_class.enqueue_after_transaction_commit
    assert_equal false, sibling_job_class.enqueue_after_transaction_commit
    assert_equal false, ActiveJob::Base.enqueue_after_transaction_commit
  end

  it "does not leak inherited Temporal transaction safety to child jobs using another adapter" do
    parent_job_class = Class.new(ActiveJob::Base) do
      include ActiveJob::EnqueueAfterTransactionCommit

      def perform; end
    end
    child_job_class = Class.new(parent_job_class) do
      include ActiveJob::EnqueueAfterTransactionCommit

      def perform; end
    end

    parent_job_class.queue_adapter = :temporal
    child_job_class.queue_adapter = :test

    assert_equal true, parent_job_class.enqueue_after_transaction_commit
    assert_equal false, child_job_class.enqueue_after_transaction_commit
  end

  it "restores inherited pre-Temporal transaction settings when a child switches away" do
    parent_job_class = Class.new(ActiveJob::Base) do
      include ActiveJob::EnqueueAfterTransactionCommit

      def perform; end
    end
    child_job_class = Class.new(parent_job_class) do
      include ActiveJob::EnqueueAfterTransactionCommit

      def perform; end
    end

    parent_job_class.queue_adapter = :temporal
    child_job_class.queue_adapter = :temporal
    child_job_class.queue_adapter = :test

    assert_equal true, parent_job_class.enqueue_after_transaction_commit
    assert_equal false, child_job_class.enqueue_after_transaction_commit
  end

  it "respects inherited explicit opt-out settings when a child uses the Temporal adapter" do
    parent_job_class = Class.new(ActiveJob::Base) do
      include ActiveJob::EnqueueAfterTransactionCommit

      self.enqueue_after_transaction_commit = false

      def perform; end
    end
    child_job_class = Class.new(parent_job_class) do
      include ActiveJob::EnqueueAfterTransactionCommit

      def perform; end
    end

    child_job_class.queue_adapter = :temporal

    assert_equal false, child_job_class.enqueue_after_transaction_commit
  end

  it "does not start a Temporal workflow when the surrounding transaction rolls back" do
    job_class.queue_adapter = :temporal

    result = job_class.perform_later
    fake_active_record.rollback!

    assert_instance_of job_class, result
    assert_empty client.start_workflow_calls
  end

  it "starts the Temporal workflow after the surrounding transaction commits" do
    job_class.queue_adapter = :temporal

    job_class.perform_later
    assert_empty client.start_workflow_calls

    fake_active_record.commit!

    assert_equal 1, client.start_workflow_calls.size
  end

  def build_configuration
    config = ActiveJob::Temporal::Configuration.new
    config.target = "localhost:7233"
    config.namespace = "default"
    config.task_queue_prefix = nil
    config
  end
end
