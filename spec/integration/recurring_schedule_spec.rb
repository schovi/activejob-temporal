# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/worker_runtime"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

RSpec.describe "Recurring schedules", :integration do
  before do
    stub_const("RecurringIdentityJob", Class.new(ActiveJob::Base) do
      class << self
        attr_accessor :executions
      end

      queue_as :default

      def perform(label)
        self.class.executions << {
          label: label,
          job_id: job_id,
          provider_job_id: provider_job_id,
          idempotency_key: Thread.current[ActiveJob::Temporal::Activities::AjRunnerActivity::IDEMPOTENCY_KEY]
        }
      end
    end)
    RecurringIdentityJob.executions = []
  end

  after do
    stop_worker(@worker_thread)
    @schedule_handle&.delete
  end

  it "creates a Temporal schedule that can trigger an ActiveJob workflow" do
    task_queue = "schedule-test-#{SecureRandom.hex(4)}"
    schedule_id = "schedule-test-#{SecureRandom.hex(4)}"
    TestJob.last_argument = nil
    @worker_thread = start_worker(task_queue)

    @schedule_handle = ActiveJob::Temporal::Schedule.new(
      TestJob,
      id: schedule_id,
      cron: "0 0 1 1 *",
      timezone: "UTC",
      args: [42],
      queue: task_queue,
      trigger_immediately: true,
      client: TemporalTestHelper.client,
      config: ActiveJob::Temporal.config
    ).create

    wait_for { TestJob.last_argument == 42 }

    description = @schedule_handle.describe
    expect(description.schedule.spec.time_zone_name).to eq("UTC")
    expect(description.info.num_actions).to be >= 1
    expect(description.info.next_action_times).not_to be_empty
  end

  it "uses a distinct execution identity for each schedule fire" do
    task_queue = "schedule-identity-test-#{SecureRandom.hex(4)}"
    schedule_id = "schedule-identity-test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)

    @schedule_handle = ActiveJob::Temporal::Schedule.new(
      RecurringIdentityJob,
      id: schedule_id,
      cron: "0 0 1 1 *",
      timezone: "UTC",
      args: ["daily"],
      queue: task_queue,
      trigger_immediately: true,
      client: TemporalTestHelper.client,
      config: ActiveJob::Temporal.config
    ).create

    wait_for { RecurringIdentityJob.executions.size == 1 }

    @schedule_handle.trigger
    wait_for { RecurringIdentityJob.executions.size == 2 }

    executions = RecurringIdentityJob.executions
    job_ids = executions.map { |execution| execution.fetch(:job_id) }
    idempotency_keys = executions.map { |execution| execution.fetch(:idempotency_key) }

    expect(job_ids.uniq.size).to eq(2)
    expect(idempotency_keys.uniq.size).to eq(2)
    expect(job_ids).to all(start_with("ajschwf:#{schedule_id}"))
    expect(executions.map { |execution| execution.fetch(:provider_job_id) }).to eq(job_ids)
  end

  private

  def start_worker(task_queue)
    Thread.new do
      worker = Temporalio::Worker.new(
        client: TemporalTestHelper.client,
        task_queue: task_queue,
        workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
        activities: [ActiveJob::Temporal::Activities::AjRunnerActivity]
      )
      worker.run
    end
  end

  def stop_worker(thread)
    return unless thread&.alive?

    thread.kill
    thread.join
  end

  def wait_for(timeout: 10)
    deadline = Time.now + timeout
    until yield
      raise "Timed out waiting for schedule execution" if Time.now > deadline

      sleep 0.1
    end
  end
end
