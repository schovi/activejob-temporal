# frozen_string_literal: true

require "spec_helper"
require "active_job"

describe ActiveJob::Temporal::WorkflowIdentity do
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "WorkflowIdentityJob"
    end
  end

  it "is included in ActiveJob::Base" do
    assert_includes ActiveJob::Base.included_modules, described_class
  end

  it "stores a stable public workflow name" do
    job_class.temporal_workflow_name "payments.charge_payment"

    assert_equal "payments.charge_payment", job_class.temporal_workflow_name
  end

  it "stores a workflow ID block" do
    block = proc { |payment_id| "payment:#{payment_id}" }

    job_class.temporal_workflow_id(&block)

    assert_same block, job_class.temporal_workflow_id
  end

  it "stores a workflow ID prefix" do
    job_class.temporal_workflow_id_prefix "payment"

    assert_equal "payment", job_class.temporal_workflow_id_prefix
  end

  it "does not inherit workflow identity from parent classes" do
    parent_class = Class.new(ActiveJob::Base) do
      temporal_workflow_name "payments.parent"
      temporal_workflow_id_prefix "parent"
    end
    child_class = Class.new(parent_class)

    assert_nil child_class.temporal_workflow_name
    assert_nil child_class.temporal_workflow_id_prefix
  end

  it "rejects blank workflow names" do
    error = assert_raises(ArgumentError) { job_class.temporal_workflow_name " " }
    assert_match(/temporal_workflow_name must be present/, error.message)
  end

  it "rejects workflow ID prefixes with control characters" do
    error = assert_raises(ArgumentError) { job_class.temporal_workflow_id_prefix "bad\nprefix" }
    assert_match(/control characters/, error.message)
  end
end
