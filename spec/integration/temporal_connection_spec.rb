# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Temporal connection", :integration do
  it "connects to the Temporal test namespace and can list workflows" do
    client = TemporalTestHelper.client

    expect(client.namespace).to eq(TemporalTestHelper::TEST_NAMESPACE)

    workflows = client.list_workflows("WorkflowId = 'temporal_connection_spec_smoke_test_marker'").to_a
    expect(workflows).to be_empty
  end
end
