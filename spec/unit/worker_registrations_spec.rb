# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/worker_runtime"

module WorkerRegistrationsSpecSupport
  class FakeExportActivity < Temporalio::Activity::Definition; end
end

describe ActiveJob::Temporal::WorkerRegistrations do
  let(:configuration) { ActiveJob::Temporal::Configuration.new }

  let(:activejob_workflows) do
    [
      ActiveJob::Temporal::Workflows::AjWorkflow,
      ActiveJob::Temporal::Workflows::DeadLetterWorkflow
    ]
  end

  let(:activejob_activities) do
    [
      ActiveJob::Temporal::Activities::RateLimitActivity,
      ActiveJob::Temporal::Activities::DependencyStatusActivity,
      ActiveJob::Temporal::Activities::AjRunnerActivity
    ]
  end

  it "registers the ActiveJob workloads by default" do
    result = described_class.resolve(configuration)

    assert_equal activejob_workflows, result.workflows
    assert_equal activejob_activities, result.activities
  end

  it "appends custom activities given as classes" do
    configuration.worker_activities = [WorkerRegistrationsSpecSupport::FakeExportActivity]

    result = described_class.resolve(configuration)

    assert_equal [WorkerRegistrationsSpecSupport::FakeExportActivity] + activejob_activities, result.activities
  end

  it "resolves custom activities given as class names" do
    configuration.worker_activities = ["WorkerRegistrationsSpecSupport::FakeExportActivity"]

    result = described_class.resolve(configuration)

    assert_includes result.activities, WorkerRegistrationsSpecSupport::FakeExportActivity
  end

  it "hosts only custom activities when the ActiveJob workloads are disabled" do
    configuration.worker_activejob_workloads = false
    configuration.worker_activities = [WorkerRegistrationsSpecSupport::FakeExportActivity]

    result = described_class.resolve(configuration)

    assert_equal [], result.workflows
    assert_equal [WorkerRegistrationsSpecSupport::FakeExportActivity], result.activities
  end

  it "raises for an unknown activity class name" do
    configuration.worker_activities = ["WorkerRegistrationsSpecSupport::MissingActivity"]

    error = assert_raises(ActiveJob::Temporal::WorkerRegistrationError) { described_class.resolve(configuration) }
    assert_match(/does not resolve to a class/, error.message)
  end

  it "raises for an entry that is not an activity definition" do
    configuration.worker_activities = [String]

    error = assert_raises(ActiveJob::Temporal::WorkerRegistrationError) { described_class.resolve(configuration) }
    assert_match(/not a Temporalio::Activity::Definition subclass/, error.message)
  end
end
