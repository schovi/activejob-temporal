# frozen_string_literal: true

require "spec_helper"
require "time"
require "activejob/temporal/workflows/aj_workflow"
require "activejob/temporal/activities/aj_runner_activity"

RSpec.describe "Temporal shim definitions" do
  let(:root_path) { File.expand_path("../..", __dir__) }
  let(:workflow_path) { File.join(root_path, "lib/activejob/temporal/workflows/aj_workflow.rb") }
  let(:activity_path) { File.join(root_path, "lib/activejob/temporal/activities/aj_runner_activity.rb") }

  around do |example|
    original_temporalio = Object.const_defined?(:Temporalio) ? Object.const_get(:Temporalio) : nil

    workflows_mod = ActiveJob::Temporal::Workflows
    activities_mod = ActiveJob::Temporal::Activities

    original_workflow_defined = workflows_mod.const_defined?(:AjWorkflow, false)
    original_workflow_class = original_workflow_defined ? workflows_mod.const_get(:AjWorkflow) : nil

    original_activity_defined = activities_mod.const_defined?(:AjRunnerActivity, false)
    original_activity_class = original_activity_defined ? activities_mod.const_get(:AjRunnerActivity) : nil

    workflows_mod.send(:remove_const, :AjWorkflow) if original_workflow_defined
    activities_mod.send(:remove_const, :AjRunnerActivity) if original_activity_defined
    Object.send(:remove_const, :Temporalio) if Object.const_defined?(:Temporalio)

    example.run
  ensure
    Object.send(:remove_const, :Temporalio) if Object.const_defined?(:Temporalio)
    Object.const_set(:Temporalio, original_temporalio) if original_temporalio

    if original_workflow_defined
      workflows_mod.send(:remove_const, :AjWorkflow) if workflows_mod.const_defined?(:AjWorkflow, false)
      workflows_mod.const_set(:AjWorkflow, original_workflow_class)
    else
      workflows_mod.send(:remove_const, :AjWorkflow) if workflows_mod.const_defined?(:AjWorkflow, false)
    end

    if original_activity_defined
      activities_mod.send(:remove_const, :AjRunnerActivity) if activities_mod.const_defined?(:AjRunnerActivity, false)
      activities_mod.const_set(:AjRunnerActivity, original_activity_class)
    else
      activities_mod.send(:remove_const, :AjRunnerActivity) if activities_mod.const_defined?(:AjRunnerActivity, false)
    end
  end

  it "provides Temporal stubs when the SDK is unavailable" do
    load workflow_path
    load activity_path

    expect(Temporalio::Workflow::Definition).to be_a(Class)

    expect(Temporalio::Activity::Definition).to be_a(Class)
    expect(Temporalio::Activity::ApplicationError.new).to be_a(Temporalio::Activity::ApplicationError)

    info = Temporalio::Activity.info
    expect(info).to be_a(Temporalio::Activity::Info)
    expect(info.workflow_id).to be_nil

    stub_const("AjRunnerActivity", ActiveJob::Temporal::Activities::AjRunnerActivity)

    current_time = Time.utc(2024, 1, 1, 0, 0, 0)
    sleep_durations = []
    activity_calls = []

    Temporalio::Workflow.define_singleton_method(:now) { current_time }
    Temporalio::Workflow.define_singleton_method(:sleep) { |duration| sleep_durations << duration }
    Temporalio::Workflow.define_singleton_method(:execute_activity) do |*args|
      activity_calls << args
      :ok
    end

    payload = {
      "job_class" => "ShimJob",
      "arguments" => ["raw"],
      "scheduled_at" => (current_time + 30).iso8601,
      "retry_policy" => { "maximum_attempts" => 2 }
    }

    shim_job_class = Class.new do
      class << self
        attr_accessor :last_instance
      end

      attr_reader :performed_args

      def initialize
        self.class.last_instance = self
      end

      def perform(*args)
        @performed_args = args
      end
    end
    stub_const("ShimJob", shim_job_class)
    shim_job_class.last_instance = nil

    allow(ActiveJob::Temporal::Payload).to receive(:deserialize_args).with(payload).and_return([1, 2])
    allow(ActiveJob::Temporal::RetryMapper).to receive(:discard_exception?).and_return(false)

    workflow = ActiveJob::Temporal::Workflows::AjWorkflow.new
    activity = ActiveJob::Temporal::Activities::AjRunnerActivity.new

    workflow.execute(payload)
    expect(sleep_durations).to contain_exactly(be_within(1e-6).of(30.0))
    expect(activity_calls.size).to eq(1)
    _, activity_payload, options = activity_calls.first
    expect(activity_payload).to eq(payload)
    expect(options[:retry]).to eq(payload["retry_policy"])
    expect(options[:start_to_close_timeout]).to eq(ActiveJob::Temporal.config.default_activity_timeout)

    activity.execute(payload)
    job_instance = shim_job_class.last_instance
    expect(job_instance.performed_args).to eq([1, 2])
    expect(ActiveJob::Temporal::Payload).to have_received(:deserialize_args).with(payload)
    expect(Thread.current[ActiveJob::Temporal::Activities::AjRunnerActivity::IDEMPOTENCY_KEY]).to be_nil

    expect(ActiveJob::Temporal::Workflows::AjWorkflow.superclass).to eq(Temporalio::Workflow::Definition)
    expect(ActiveJob::Temporal::Activities::AjRunnerActivity.superclass).to eq(Temporalio::Activity::Definition)
  end
end
