# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/workflows/dead_letter_workflow"

RSpec.describe ActiveJob::Temporal::Workflows::DeadLetterWorkflow do
  subject(:workflow) { described_class.new }

  let(:entry) do
    {
      "id" => "entry-1",
      "state" => "pending",
      "payload" => { "job_class" => "RetryableJob" },
      "metadata" => { "job_id" => "job-123" },
      "failure" => { "class" => "StandardError", "message" => "boom" }
    }
  end

  before do
    allow(Temporalio::Workflow).to receive(:now).and_return(Time.utc(2026, 5, 21, 10, 0, 0))
    allow(Temporalio::Workflow).to receive(:wait_condition) { |&condition| condition.call }
  end

  it "exposes the pending entry through a workflow query" do
    workflow.execute(entry)

    expect(workflow.entry).to include("id" => "entry-1", "state" => "pending")
  end

  it "marks an entry retried and completes" do
    workflow.mark_retried("retry-workflow-1")

    result = workflow.execute(entry)

    expect(result).to include(
      "id" => "entry-1",
      "state" => "retried",
      "retry_workflow_id" => "retry-workflow-1",
      "retried_at" => "2026-05-21T10:00:00Z"
    )
  end

  it "marks an entry discarded and completes" do
    workflow.discard("handled elsewhere")

    result = workflow.execute(entry)

    expect(result).to include(
      "id" => "entry-1",
      "state" => "discarded",
      "discard_reason" => "handled elsewhere",
      "discarded_at" => "2026-05-21T10:00:00Z"
    )
  end

  it "keeps the first terminal state" do
    workflow.mark_retried("retry-workflow-1")
    workflow.execute(entry)
    workflow.discard("too late")

    expect(workflow.entry).to include("state" => "retried", "retry_workflow_id" => "retry-workflow-1")
    expect(workflow.entry).not_to have_key("discard_reason")
  end
end
