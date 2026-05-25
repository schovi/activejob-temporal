# frozen_string_literal: true

require "spec_helper"
require "active_job/enqueue_after_transaction_commit"

RSpec.describe "ActiveJob::Temporal transaction safety" do
  let(:client) { instance_double(Temporalio::Client) }
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

    allow(ActiveJob::Temporal).to receive(:client).and_return(client)
    allow(ActiveJob::Temporal).to receive(:config).and_return(config)
    allow(client).to receive(:start_workflow).and_return("workflow-handle")
    allow(ActiveJob::Temporal::Logger).to receive(:log_event)
  end

  it "enables the Rails transaction commit setting when a job uses the Temporal adapter" do
    expect(job_class.enqueue_after_transaction_commit).to be false

    job_class.queue_adapter = :temporal

    expect(job_class.enqueue_after_transaction_commit).to be true
  end

  it "enables transaction safety when a Temporal adapter instance is assigned" do
    expect(job_class.enqueue_after_transaction_commit).to be false

    job_class.queue_adapter = ActiveJob::QueueAdapters::TemporalAdapter.new

    expect(job_class.enqueue_after_transaction_commit).to be true
  end

  it "restores the previous transaction commit setting when switching away from Temporal" do
    expect(job_class.enqueue_after_transaction_commit).to be false

    job_class.queue_adapter = :temporal
    job_class.queue_adapter = :test

    expect(job_class.enqueue_after_transaction_commit).to be false
  end

  it "restores a previous explicit transaction commit setting when switching away from Temporal" do
    job_class.enqueue_after_transaction_commit = true

    job_class.queue_adapter = :temporal
    job_class.queue_adapter = :test

    expect(job_class.enqueue_after_transaction_commit).to be true
  end

  it "respects an explicit job-level opt-out before selecting the Temporal adapter" do
    job_class.enqueue_after_transaction_commit = false

    job_class.queue_adapter = :temporal

    expect(job_class.enqueue_after_transaction_commit).to be false
  end

  it "respects an explicit job-level opt-out after selecting the Temporal adapter" do
    job_class.queue_adapter = :temporal
    job_class.enqueue_after_transaction_commit = false

    job_class.queue_adapter = :temporal

    expect(job_class.enqueue_after_transaction_commit).to be false
  end

  it "keeps per-job Temporal adapter transaction settings scoped to that job class" do
    sibling_job_class = Class.new(ActiveJob::Base) do
      include ActiveJob::EnqueueAfterTransactionCommit

      def perform; end
    end

    job_class.queue_adapter = :temporal
    sibling_job_class.queue_adapter = :test

    expect(job_class.enqueue_after_transaction_commit).to be true
    expect(sibling_job_class.enqueue_after_transaction_commit).to be false
    expect(ActiveJob::Base.enqueue_after_transaction_commit).to be false
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

    expect(parent_job_class.enqueue_after_transaction_commit).to be true
    expect(child_job_class.enqueue_after_transaction_commit).to be false
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

    expect(parent_job_class.enqueue_after_transaction_commit).to be true
    expect(child_job_class.enqueue_after_transaction_commit).to be false
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

    expect(child_job_class.enqueue_after_transaction_commit).to be false
  end

  it "does not start a Temporal workflow when the surrounding transaction rolls back" do
    job_class.queue_adapter = :temporal

    result = job_class.perform_later
    fake_active_record.rollback!

    expect(result).to be_a(job_class)
    expect(client).not_to have_received(:start_workflow)
  end

  it "starts the Temporal workflow after the surrounding transaction commits" do
    job_class.queue_adapter = :temporal

    job_class.perform_later
    expect(client).not_to have_received(:start_workflow)

    fake_active_record.commit!

    expect(client).to have_received(:start_workflow).once
  end

  def build_configuration
    config = ActiveJob::Temporal::Configuration.new
    config.target = "localhost:7233"
    config.namespace = "default"
    config.task_queue_prefix = nil
    config
  end
end
