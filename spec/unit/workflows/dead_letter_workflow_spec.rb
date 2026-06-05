# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/workflows/dead_letter_workflow"

describe ActiveJob::Temporal::Workflows::DeadLetterWorkflow do
  let(:workflow) { described_class.new }

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
    call_recorded_method(Temporalio::Workflow, :now, returns: Time.utc(2026, 5, 21, 10, 0, 0))
    call_recorded_method(Temporalio::Workflow, :wait_condition) { |&condition| condition.call }
  end

  it "exposes the pending entry through a workflow query" do
    workflow.execute(entry)

    assert_equal "entry-1", workflow.entry.fetch("id")
    assert_equal "pending", workflow.entry.fetch("state")
  end

  it "marks an entry retried and completes" do
    workflow.mark_retried("retry-workflow-1")

    result = workflow.execute(entry)

    assert_equal "entry-1", result.fetch("id")
    assert_equal "retried", result.fetch("state")
    assert_equal "retry-workflow-1", result.fetch("retry_workflow_id")
    assert_equal "2026-05-21T10:00:00Z", result.fetch("retried_at")
  end

  it "marks an entry discarded and completes" do
    workflow.discard("handled elsewhere")

    result = workflow.execute(entry)

    assert_equal "entry-1", result.fetch("id")
    assert_equal "discarded", result.fetch("state")
    assert_equal "handled elsewhere", result.fetch("discard_reason")
    assert_equal "2026-05-21T10:00:00Z", result.fetch("discarded_at")
  end

  it "keeps the first terminal state" do
    workflow.mark_retried("retry-workflow-1")
    workflow.execute(entry)
    workflow.discard("too late")

    assert_equal "retried", workflow.entry.fetch("state")
    assert_equal "retry-workflow-1", workflow.entry.fetch("retry_workflow_id")
    refute workflow.entry.key?("discard_reason")
  end

  it "auto-discards pending entries when the configured retention expires" do
    timeout_calls = call_recorded_method(Temporalio::Workflow, :timeout, raises: Timeout::Error.new)

    result = workflow.execute(
      entry.merge(
        "metadata" => entry.fetch("metadata").merge("auto_discard_after_seconds" => 86_400)
      )
    )

    assert_equal "discarded", result.fetch("state")
    assert_equal "auto_discard_after_expired", result.fetch("discard_reason")
    assert_equal "2026-05-21T10:00:00Z", result.fetch("discarded_at")
    assert_called_with(
      timeout_calls,
      :timeout,
      86_400.0,
      Timeout::Error,
      "dead letter auto-discard expired",
      summary: "Dead letter auto-discard"
    )
  end

  it "does not auto-discard when the entry reaches a terminal state before retention expires" do
    call_recorded_method(Temporalio::Workflow, :timeout) do |*_args, **_kwargs, &block|
      block.call
    end
    workflow.mark_retried("retry-workflow-1")

    result = workflow.execute(
      entry.merge(
        "metadata" => entry.fetch("metadata").merge("auto_discard_after_seconds" => 86_400)
      )
    )

    assert_equal "retried", result.fetch("state")
    assert_equal "retry-workflow-1", result.fetch("retry_workflow_id")
    refute result.key?("discard_reason")
  end
end
