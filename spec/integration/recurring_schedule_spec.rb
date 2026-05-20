# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

RSpec.describe "Recurring schedules", :integration do
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
    expect(description.schedule.spec.cron_expressions).to include("0 0 1 1 *")
    expect(description.schedule.spec.time_zone_name).to eq("UTC")
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
