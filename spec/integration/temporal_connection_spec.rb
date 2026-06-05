# frozen_string_literal: true

require "spec_helper"

describe "Temporal connection", :integration do
  it "connects to the Temporal test namespace and can list workflows" do
    client = TemporalTestHelper.client

    assert_equal TemporalTestHelper::TEST_NAMESPACE, client.namespace

    workflows = client.list_workflows("WorkflowId = 'temporal_connection_spec_smoke_test_marker'").to_a
    assert_empty workflows
  end
end
