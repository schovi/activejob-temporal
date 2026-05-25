# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/worker_runtime"
require "timeout"
require "securerandom"
require "temporalio/worker"

RSpec.describe "ActiveJob Temporal dead letter queue", :integration do
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    original_dead_letter_queue = ActiveJob::Temporal.config.dead_letter_queue
    original_dead_letter_after_attempts = ActiveJob::Temporal.config.dead_letter_after_attempts
    ActiveJob::Base.queue_adapter = :temporal
    TestState.instance.reset!

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    ActiveJob::Temporal.config.dead_letter_after_attempts = original_dead_letter_after_attempts
    ActiveJob::Temporal.config.dead_letter_queue = original_dead_letter_queue
    stop_worker(@worker_thread)
    stop_worker(@dead_letter_worker_thread)
    TestState.instance.reset!
  end

  def client
    TemporalTestHelper.client
  end

  it "captures a permanently failed job, retries it manually, and discards another entry" do
    task_queue = "dlq-source-#{SecureRandom.hex(4)}"
    dead_letter_queue = "dlq-failed-#{SecureRandom.hex(4)}"
    ActiveJob::Temporal.config.dead_letter_queue = dead_letter_queue
    ActiveJob::Temporal.config.dead_letter_after_attempts = 2
    @worker_thread = start_worker(task_queue)
    @dead_letter_worker_thread = start_worker(dead_letter_queue)
    sleep 0.5

    retryable_job_class = stub_const("DeadLetterRetryIntegrationJob", Class.new(ActiveJob::Base) do
      retry_on StandardError, wait: 1, attempts: 2

      def perform(result)
        TestState.instance.attempt_count += 1
        raise StandardError, "permanent failure" if TestState.instance.attempt_count <= 2

        TestState.instance.test_result = result
      end
    end)

    job = retryable_job_class.set(queue: task_queue).perform_later("retried")
    wait_for_workflow_failure(ActiveJob::Temporal::Adapter.build_workflow_id(job))
    entry = wait_for_dead_letter_entry("DeadLetterRetryIntegrationJob")

    expect(entry).to include(
      "state" => "pending",
      "failure" => hash_including("class" => "StandardError", "message" => "permanent failure"),
      "metadata" => hash_including(
        "job_class" => "DeadLetterRetryIntegrationJob",
        "attempt" => 2,
        "max_attempts" => 2,
        "original_task_queue" => task_queue
      )
    )

    retry_workflow_id = ActiveJob::Temporal::DeadLetterQueue.retry(retryable_job_class, job.job_id)
    wait_for_result("retried")
    wait_for_workflow_completion(retry_workflow_id)

    discard_job_class = stub_const("DeadLetterDiscardIntegrationJob", Class.new(ActiveJob::Base) do
      retry_on StandardError, wait: 1, attempts: 2

      def perform
        raise StandardError, "discard me"
      end
    end)

    discard_job = discard_job_class.set(queue: task_queue).perform_later
    wait_for_workflow_failure(ActiveJob::Temporal::Adapter.build_workflow_id(discard_job))
    discard_entry = wait_for_dead_letter_entry("DeadLetterDiscardIntegrationJob")
    ActiveJob::Temporal::DeadLetterQueue.discard(discard_job_class, discard_job.job_id)

    wait_for_workflow_completion(discard_entry.fetch("id"))
  end

  private

  def start_worker(task_queue)
    Thread.new do
      worker = Temporalio::Worker.new(
        client: TemporalTestHelper.client,
        task_queue: task_queue,
        workflows: [
          ActiveJob::Temporal::Workflows::AjWorkflow,
          ActiveJob::Temporal::Workflows::DeadLetterWorkflow
        ],
        activities: [ActiveJob::Temporal::Activities::AjRunnerActivity]
      )
      worker.run
    end
  end

  def stop_worker(thread)
    return unless thread&.alive?

    thread.kill
    thread.join(5)
  end

  def wait_for_dead_letter_entry(job_class_name)
    Timeout.timeout(15) do
      loop do
        entry = ActiveJob::Temporal::DeadLetterQueue.entries.find do |candidate|
          candidate.dig("metadata", "job_class") == job_class_name
        end
        return entry if entry

        sleep 0.1
      end
    end
  end

  def wait_for_result(expected)
    Timeout.timeout(15) do
      loop do
        break if TestState.instance.test_result == expected

        sleep 0.1
      end
    end
  end

  def wait_for_workflow_completion(workflow_id)
    handle = client.workflow_handle(workflow_id)
    Timeout.timeout(15) do
      loop do
        description = handle.describe
        break if description.status == Temporalio::Client::WorkflowExecutionStatus::COMPLETED

        sleep 0.1
      end
    end
  end

  def wait_for_workflow_failure(workflow_id)
    handle = client.workflow_handle(workflow_id)
    Timeout.timeout(15) do
      loop do
        description = handle.describe
        break if description.status == Temporalio::Client::WorkflowExecutionStatus::FAILED

        sleep 0.1
      end
    end
  end
end
