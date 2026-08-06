# frozen_string_literal: true

require "spec_helper"
require "temporalio/worker"
require "activejob/temporal/rails_environment_loader"

require "temporalio/activity"

module WorkerConfigurationSpecSupport
  class FakeExportActivity < Temporalio::Activity::Definition; end
end

describe "Worker configuration" do
  let(:client) { Object.new }
  let(:worker) { Object.new }
  let(:config) { ActiveJob::Temporal::Configuration.new }

  around do |example|
    original_argv = ARGV.dup
    original_rails_root = ENV.fetch("RAILS_ROOT", nil)
    original_activejob_temporal_env = ENV.select { |key, _value| key.start_with?("ACTIVEJOB_TEMPORAL_") }

    ARGV.replace([])
    ENV.delete("RAILS_ROOT")
    ENV.delete_if { |key, _value| key.start_with?("ACTIVEJOB_TEMPORAL_") }

    example.run
  ensure
    ARGV.replace(original_argv)
    ENV["RAILS_ROOT"] = original_rails_root unless original_rails_root.nil?
    ENV.delete("RAILS_ROOT") if original_rails_root.nil?
    ENV.delete_if { |key, _value| key.start_with?("ACTIVEJOB_TEMPORAL_") }
    original_activejob_temporal_env.each { |key, value| ENV[key] = value }
  end

  before do
    config.max_concurrent_activities = 37
    config.max_concurrent_workflow_tasks = 8

    call_recorded_method(ActiveJob::Temporal::RailsEnvironmentLoader, :load!)
    call_recorded_method(ActiveJob::Temporal, :client, returns: client)
    call_recorded_method(ActiveJob::Temporal, :config, returns: config)
    call_recorded_method(ActiveJob::Temporal::Logger, :log_event)
    call_recorded_method(Signal, :trap)
    call_recorded_method(Temporalio::Worker, :run_all)
  end

  it "uses configured concurrency values as Temporal execution slots" do
    worker_options = load_worker_options

    tuner = worker_options.fetch(:tuner)
    assert_equal 37, tuner.activity_slot_supplier.slots
    assert_equal 37, tuner.local_activity_slot_supplier.slots
    assert_equal 8, tuner.workflow_slot_supplier.slots
  end

  it "leaves SDK poller counts on their own defaults" do
    worker_options = load_worker_options

    refute_includes worker_options, :max_concurrent_activity_task_polls
    refute_includes worker_options, :max_concurrent_workflow_task_polls
  end

  it "registers configured custom activities ahead of the ActiveJob workloads" do
    config.worker_activities = [WorkerConfigurationSpecSupport::FakeExportActivity]

    worker_options = load_worker_options

    assert_equal(
      [ActiveJob::Temporal::Workflows::AjWorkflow, ActiveJob::Temporal::Workflows::DeadLetterWorkflow],
      worker_options.fetch(:workflows)
    )
    assert_equal(
      [
        WorkerConfigurationSpecSupport::FakeExportActivity,
        ActiveJob::Temporal::Activities::RateLimitActivity,
        ActiveJob::Temporal::Activities::DependencyStatusActivity,
        ActiveJob::Temporal::Activities::AjRunnerActivity
      ],
      worker_options.fetch(:activities)
    )
  end

  it "hosts an activities-only worker when the ActiveJob workloads are disabled" do
    config.worker_activejob_workloads = false
    config.worker_activities = [WorkerConfigurationSpecSupport::FakeExportActivity]

    worker_options = load_worker_options

    assert_equal [], worker_options.fetch(:workflows)
    assert_equal [WorkerConfigurationSpecSupport::FakeExportActivity], worker_options.fetch(:activities)
  end

  it "passes the configured graceful shutdown period to the worker" do
    config.graceful_shutdown_period = 105.0

    worker_options = load_worker_options

    assert_equal 105.0, worker_options.fetch(:graceful_shutdown_period)
  end

  def load_worker_options
    worker_options = nil
    call_recorded_method(Temporalio::Worker, :new) do |**options|
      worker_options = options
      worker
    end

    load File.expand_path("../../bin/temporal-worker", __dir__)

    worker_options
  end
end
