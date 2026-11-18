# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "timeout"

module StuckJobsIntegrationSupport
  class FailingWorkflow < Temporalio::Workflow::Definition
    workflow_name ActiveJob::Temporal::WorkflowTypes::ACTIVE_JOB

    def execute(_payload)
      raise "workflow task failed before scheduling the job activity"
    end
  end

  class ProbeJob < ActiveJob::Base
    self.queue_adapter = :temporal
  end
end

describe "ActiveJob Temporal stuck job detection", :integration do
  after do
    @handle&.terminate("Stuck jobs integration test cleanup")
  ensure
    stop_temporal_worker(@worker_thread)
  end

  it "lists and counts a running job after its workflow task fails" do
    client = TemporalTestHelper.client
    request = Temporalio::Api::WorkflowService::V1::DescribeNamespaceRequest.new(namespace: client.namespace)
    capabilities = client.workflow_service.describe_namespace(request).namespace_info&.capabilities
    skip "Namespace does not report workflow task problems" unless capabilities&.reported_problems_search_attribute

    queue = "stuck-jobs-#{SecureRandom.hex(4)}"
    job_class = StuckJobsIntegrationSupport::ProbeJob
    job = job_class.set(queue: queue).perform_later
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)
    @handle = client.workflow_handle(workflow_id)
    @worker_thread = start_temporal_worker(
      ActiveJob::Temporal::Adapter.resolve_task_queue(job),
      workflows: [StuckJobsIntegrationSupport::FailingWorkflow],
      activities: []
    )

    entry, count = wait_for_stuck_job(job_class, workflow_id, queue)

    assert_equal job.job_id, entry.fetch(:job_id)
    assert_equal queue, entry.fetch(:queue)
    assert_includes entry.fetch(:problems), "category=WorkflowTaskFailed"
    assert_equal 1, count
  end

  private

  def wait_for_stuck_job(job_class, workflow_id, queue)
    Timeout.timeout(30) do
      loop do
        entry = ActiveJob::Temporal.stuck_jobs(job_class: job_class).find do |candidate|
          candidate.fetch(:workflow_id) == workflow_id
        end
        count = ActiveJob::Temporal.count_stuck_jobs(job_class: job_class, queue: queue)
        return [entry, count] if entry && count.positive?

        sleep 0.1
      end
    end
  end
end
