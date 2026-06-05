# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/worker_runtime"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

describe "Recurring schedules", :integration do
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
    assert_equal "UTC", description.schedule.spec.time_zone_name
    assert_operator description.info.num_actions, :>=, 1
    refute_empty description.info.next_action_times
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

    assert_equal 2, job_ids.uniq.size
    assert_equal 2, idempotency_keys.uniq.size
    provider_job_ids = executions.map { |execution| execution.fetch(:provider_job_id) }

    assert(job_ids.all? { |job_id| job_id.start_with?("ajschwf:#{schedule_id}") })
    assert_equal job_ids, provider_job_ids
  end

  private

  def start_worker(task_queue)
    start_temporal_worker(task_queue)
  end

  def stop_worker(thread)
    stop_temporal_worker(thread)
  end

  def wait_for(timeout: 10)
    deadline = Time.now + timeout
    until yield
      raise "Timed out waiting for schedule execution" if Time.now > deadline

      sleep 0.1
    end
  end
end
