# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe ActiveJob::Temporal::WorkflowIdentity do
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "WorkflowIdentityJob"
    end
  end

  it "is included in ActiveJob::Base" do
    expect(ActiveJob::Base.included_modules).to include(described_class)
  end

  it "stores a stable public workflow name" do
    job_class.temporal_workflow_name "payments.charge_payment"

    expect(job_class.temporal_workflow_name).to eq("payments.charge_payment")
  end

  it "stores a workflow ID block" do
    block = proc { |payment_id| "payment:#{payment_id}" }

    job_class.temporal_workflow_id(&block)

    expect(job_class.temporal_workflow_id).to equal(block)
  end

  it "stores a workflow ID prefix" do
    job_class.temporal_workflow_id_prefix "payment"

    expect(job_class.temporal_workflow_id_prefix).to eq("payment")
  end

  it "does not inherit workflow identity from parent classes" do
    parent_class = Class.new(ActiveJob::Base) do
      temporal_workflow_name "payments.parent"
      temporal_workflow_id_prefix "parent"
    end
    child_class = Class.new(parent_class)

    expect(child_class.temporal_workflow_name).to be_nil
    expect(child_class.temporal_workflow_id_prefix).to be_nil
  end

  it "rejects blank workflow names" do
    expect { job_class.temporal_workflow_name " " }
      .to raise_error(ArgumentError, /temporal_workflow_name must be present/)
  end

  it "rejects workflow ID prefixes with control characters" do
    expect { job_class.temporal_workflow_id_prefix "bad\nprefix" }
      .to raise_error(ArgumentError, /control characters/)
  end
end
