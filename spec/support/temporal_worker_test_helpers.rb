# frozen_string_literal: true

require "temporalio/cancellation"
require "temporalio/worker"

module TemporalWorkerTestHelpers
  CANCEL_WORKER_THREAD_KEY = :activejob_temporal_cancel_worker

  def start_temporal_worker(
    task_queue,
    client: TemporalTestHelper.client,
    workflows: nil,
    activities: nil,
    **worker_options
  )
    cancellation, cancel_worker = Temporalio::Cancellation.new
    worker = Temporalio::Worker.new(
      client: client,
      task_queue: task_queue,
      workflows: workflows || default_temporal_workflows,
      activities: activities || default_temporal_activities,
      **worker_options
    )
    thread = Thread.new { worker.run(cancellation: cancellation) }
    thread.thread_variable_set(CANCEL_WORKER_THREAD_KEY, cancel_worker)
    thread
  end

  def stop_temporal_worker(thread)
    return unless thread&.alive?

    cancel_worker = thread.thread_variable_get(CANCEL_WORKER_THREAD_KEY)
    cancel_worker&.call(reason: "test cleanup")
    thread.join(5)
    return unless thread.alive?

    # Native Temporal pollers should shut down cooperatively, but failed tests
    # still need a bounded cleanup path.
    thread.kill
    thread.join(5)
  end

  private

  def default_temporal_workflows
    [ActiveJob::Temporal::Workflows::AjWorkflow]
  end

  def default_temporal_activities
    [ActiveJob::Temporal::Activities::AjRunnerActivity]
  end
end

Minitest::Spec.include(TemporalWorkerTestHelpers)
