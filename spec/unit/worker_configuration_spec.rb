# frozen_string_literal: true

require "spec_helper"
require "temporalio/worker"

RSpec.describe "Worker configuration" do
  let(:client) { double("Temporal client") }
  let(:worker) { instance_double(Temporalio::Worker) }
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

    allow(ActiveJob::Temporal::RailsEnvironmentLoader).to receive(:load!)
    allow(ActiveJob::Temporal).to receive(:client).and_return(client)
    allow(ActiveJob::Temporal).to receive(:config).and_return(config)
    allow(ActiveJob::Temporal::Logger).to receive(:log_event)
    allow(Signal).to receive(:trap)
    allow(Temporalio::Worker).to receive(:run_all)
  end

  it "uses configured concurrency values as Temporal execution slots" do
    worker_options = load_worker_options

    tuner = worker_options.fetch(:tuner)
    expect(tuner.activity_slot_supplier.slots).to eq(37)
    expect(tuner.local_activity_slot_supplier.slots).to eq(37)
    expect(tuner.workflow_slot_supplier.slots).to eq(8)
  end

  it "leaves SDK poller counts on their own defaults" do
    worker_options = load_worker_options

    expect(worker_options).not_to include(:max_concurrent_activity_task_polls)
    expect(worker_options).not_to include(:max_concurrent_workflow_task_polls)
  end

  def load_worker_options
    worker_options = nil
    allow(Temporalio::Worker).to receive(:new) do |**options|
      worker_options = options
      worker
    end

    load File.expand_path("../../bin/temporal-worker", __dir__)

    worker_options
  end
end
