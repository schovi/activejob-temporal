# frozen_string_literal: true

require "activejob/temporal"
require "temporalio/worker"
require_relative "../fixtures/chaos_jobs"

ActiveJob::Temporal.configure do |config|
  config.target = ENV.fetch("TEMPORAL_TEST_TARGET", "127.0.0.1:7233")
  config.namespace = "test"
  config.task_queue = ENV.fetch("ACTIVEJOB_TEMPORAL_TASK_QUEUE")
end

worker = Temporalio::Worker.new(
  client: ActiveJob::Temporal.client,
  task_queue: ActiveJob::Temporal.config.task_queue,
  workflows: [
    ActiveJob::Temporal::Workflows::AjWorkflow,
    ActiveJob::Temporal::Workflows::DeadLetterWorkflow
  ],
  activities: [
    ActiveJob::Temporal::Activities::DependencyStatusActivity,
    ActiveJob::Temporal::Activities::RateLimitActivity,
    ActiveJob::Temporal::Activities::AjRunnerActivity
  ]
)

worker.run(shutdown_signals: %w[SIGINT SIGTERM])
