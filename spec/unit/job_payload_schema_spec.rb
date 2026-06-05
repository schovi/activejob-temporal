# frozen_string_literal: true

require "json"
require "spec_helper"

describe "job payload schema" do
  let(:schema) { JSON.parse(File.read("api/job_payload_schema.json")) }

  it "allows workflow-control metadata for all payload formats" do
    expected_properties = {
      "default_activity_options" => { "type" => "object" },
      "retry_policy" => { "type" => "object" },
      "temporal_options" => { "type" => "object" },
      "dead_letter" => { "type" => "object" },
      "workflow_identity" => { "$ref" => "#/definitions/workflow_identity" },
      "workflow_interactions" => { "$ref" => "#/definitions/workflow_interactions" },
      "rate_limits" => { "$ref" => "#/definitions/rate_limits" },
      "child_workflows" => { "$ref" => "#/definitions/child_workflows" },
      "chain" => { "$ref" => "#/definitions/chain" },
      "dependencies" => { "$ref" => "#/definitions/dependencies" },
      "dependency_failure_policy" => { "type" => "string", "enum" => %w[fail ignore] },
      "dependency_wait" => { "$ref" => "#/definitions/dependency_wait" },
      "activity_task_queue" => { "type" => "string", "minLength" => 1 },
      "schedule_id" => { "type" => "string", "minLength" => 1 },
      "schedule_workflow_id_prefix" => { "type" => "string", "minLength" => 1 },
      "schedule_execution_job_id" => { "type" => "string", "minLength" => 1 },
      "payload_encryption_context" => { "$ref" => "#/definitions/payload_encryption_context" }
    }

    schema.fetch("oneOf").each do |payload_branch|
      assert_hash_includes expected_properties, payload_branch.fetch("properties")
    end
  end

  it "defines workflow interaction metadata" do
    interaction_schema = schema.fetch("definitions").fetch("workflow_interactions")
    properties = interaction_schema.fetch("properties")

    assert_equal "object", interaction_schema.fetch("type")
    assert_equal false, interaction_schema.fetch("additionalProperties")
    assert_unordered_equal %w[job_class signals queries updates], interaction_schema.fetch("required")
    assert_hash_includes({ "job_class" => { "type" => "string", "minLength" => 1 } }, properties)
    assert_hash_includes({ "type" => "array", "uniqueItems" => true }, properties.fetch("signals"))
    assert_hash_includes({ "type" => "array", "uniqueItems" => true }, properties.fetch("queries"))
    assert_hash_includes({ "type" => "array", "uniqueItems" => true }, properties.fetch("updates"))
  end

  it "defines nested ActiveJob execution metadata" do
    active_job_schema = schema.fetch("definitions").fetch("active_job_payload")
    active_job_properties = active_job_schema.fetch("properties")

    assert_equal "object", active_job_schema.fetch("type")
    assert_equal true, active_job_schema.fetch("additionalProperties")
    assert_unordered_equal %w[job_class job_id queue_name arguments], active_job_schema.fetch("required")
    assert_hash_includes(
      {
        "job_class" => { "type" => "string", "minLength" => 1 },
        "job_id" => { "type" => "string", "minLength" => 1 },
        "queue_name" => { "type" => "string", "minLength" => 1 },
        "arguments" => { "type" => "array" }
      },
      active_job_properties
    )

    json_payload_branch = payload_branch_requiring("job_class")
    assert_unordered_equal %w[job_class job_id queue_name], json_payload_branch.fetch("required")
    assert_unordered_equal(
      [
        { "required" => ["active_job"] },
        { "required" => ["arguments"] }
      ],
      json_payload_branch.fetch("anyOf")
    )
    assert_hash_includes(
      {
        "arguments" => { "type" => "array" },
        "active_job" => { "$ref" => "#/definitions/active_job_payload" }
      },
      json_payload_branch.fetch("properties")
    )
  end

  it "defines workflow identity metadata" do
    identity_schema = schema.fetch("definitions").fetch("workflow_identity")

    assert_equal "object", identity_schema.fetch("type")
    assert_equal false, identity_schema.fetch("additionalProperties")
    assert_equal ["workflow_name"], identity_schema.fetch("required")
    assert_hash_includes(
      {
        "workflow_name" => { "type" => "string", "minLength" => 1 },
        "workflow_id_prefix" => { "type" => "string", "minLength" => 1 }
      },
      identity_schema.fetch("properties")
    )
  end

  it "allows serialized payload envelopes" do
    serialized_branch = payload_branch_requiring("serialized_payload")

    assert_unordered_equal(
      %w[serialized_payload payload_serializer payload_serializer_version serialized_data],
      serialized_branch.fetch("required")
    )
    assert_hash_includes(
      {
        "payload_serializer" => { "type" => "string", "enum" => %w[message_pack marshal] },
        "payload_serializer_version" => { "type" => "integer", "enum" => [1] },
        "serialized_data" => { "type" => "string" }
      },
      serialized_branch.fetch("properties")
    )
  end

  it "allows serializer metadata on encrypted payloads" do
    encrypted_branch = payload_branch_requiring("encrypted_payload")

    assert_equal(
      {
        "payload_serializer" => ["payload_serializer_version"],
        "payload_serializer_version" => ["payload_serializer"]
      },
      encrypted_branch.fetch("dependencies")
    )
    assert_hash_includes(
      {
        "payload_serializer" => { "type" => "string", "enum" => %w[message_pack marshal] },
        "payload_serializer_version" => { "type" => "integer", "enum" => [1] }
      },
      encrypted_branch.fetch("properties")
    )
  end

  it "allows v2 encrypted payload metadata" do
    encrypted_branch = payload_branch_requiring("encrypted_payload")

    assert_hash_includes(
      {
        "encrypted_payload_version" => { "type" => "integer", "enum" => [1, 2] },
        "encrypted_key_id" => { "type" => "string", "minLength" => 1 },
        "encrypted_iv" => { "type" => "string" },
        "encrypted_auth_tag" => { "type" => "string" }
      },
      encrypted_branch.fetch("properties")
    )
  end

  it "allows external payload envelopes" do
    external_branch = payload_branch_requiring("external_payload")

    assert_unordered_equal(
      %w[external_payload external_payload_version external_payload_reference],
      external_branch.fetch("required")
    )
    assert_hash_includes(
      {
        "external_payload" => { "const" => true },
        "external_payload_version" => { "type" => "integer", "enum" => [1] },
        "external_payload_reference" => {}
      },
      external_branch.fetch("properties")
    )
  end

  it "requires normalized rate limit entries" do
    rate_limit_schema = schema.fetch("definitions").fetch("rate_limit")

    assert_unordered_equal %w[limit interval key], rate_limit_schema.fetch("required")
    assert_equal false, rate_limit_schema.fetch("additionalProperties")
  end

  it "defines dependency metadata" do
    dependency_schema = schema.fetch("definitions").fetch("dependency")

    assert_equal "object", dependency_schema.fetch("type")
    assert_equal false, dependency_schema.fetch("additionalProperties")
    assert_unordered_equal(
      [
        { "required" => ["job_id"] },
        { "required" => ["workflow_id"] }
      ],
      dependency_schema.fetch("anyOf")
    )
    assert_hash_includes(
      {
        "job_class" => { "type" => "string", "minLength" => 1 },
        "job_id" => { "type" => "string", "minLength" => 1 },
        "workflow_id" => { "type" => "string", "minLength" => 1 },
        "run_id" => { "type" => "string", "minLength" => 1 }
      },
      dependency_schema.fetch("properties")
    )
  end

  it "defines dependency wait metadata" do
    dependency_wait_schema = schema.fetch("definitions").fetch("dependency_wait")

    assert_equal "object", dependency_wait_schema.fetch("type")
    assert_equal false, dependency_wait_schema.fetch("additionalProperties")
    assert_unordered_equal %w[timeout initial_interval max_interval backoff], dependency_wait_schema.fetch("required")
    assert_hash_includes(
      {
        "timeout" => { "type" => "number", "exclusiveMinimum" => 0 },
        "initial_interval" => { "type" => "number", "exclusiveMinimum" => 0 },
        "max_interval" => { "type" => "number", "exclusiveMinimum" => 0 },
        "backoff" => { "type" => "number", "minimum" => 1.0 }
      },
      dependency_wait_schema.fetch("properties")
    )
  end

  it "defines child workflow metadata" do
    child_workflow_schema = schema.fetch("definitions").fetch("active_job_child_workflow")

    assert_equal "object", child_workflow_schema.fetch("type")
    assert_equal false, child_workflow_schema.fetch("additionalProperties")
    assert_unordered_equal(
      %w[job_class job_id workflow_id queue_name arguments],
      child_workflow_schema.fetch("required")
    )
    assert_hash_includes(
      {
        "job_class" => { "type" => "string", "minLength" => 1 },
        "job_id" => { "type" => "string", "minLength" => 1 },
        "workflow_id" => { "type" => "string", "minLength" => 1 },
        "workflow_task_queue" => { "type" => "string", "minLength" => 1 },
        "search_attributes" => { "$ref" => "#/definitions/child_workflow_search_attributes" }
      },
      child_workflow_schema.fetch("properties")
    )
  end

  it "defines external Temporal chain step metadata" do
    external_chain_step_schema = schema.fetch("definitions").fetch("external_chain_step")

    assert_equal "object", external_chain_step_schema.fetch("type")
    assert_equal false, external_chain_step_schema.fetch("additionalProperties")
    assert_unordered_equal %w[temporal_operation temporal_type options], external_chain_step_schema.fetch("required")
    assert_hash_includes(
      {
        "temporal_operation" => { "type" => "string", "enum" => %w[activity workflow] },
        "temporal_type" => { "type" => "string", "minLength" => 1 },
        "options" => { "$ref" => "#/definitions/external_temporal_options" }
      },
      external_chain_step_schema.fetch("properties")
    )
  end

  it "defines external Temporal child workflow metadata" do
    external_child_workflow_schema = schema.fetch("definitions").fetch("external_child_workflow")

    assert_equal "object", external_child_workflow_schema.fetch("type")
    assert_equal false, external_child_workflow_schema.fetch("additionalProperties")
    assert_unordered_equal(
      %w[temporal_operation temporal_type options],
      external_child_workflow_schema.fetch("required")
    )
    assert_hash_includes(
      {
        "temporal_operation" => { "type" => "string", "enum" => ["workflow"] },
        "temporal_type" => { "type" => "string", "minLength" => 1 },
        "options" => { "$ref" => "#/definitions/external_temporal_options" }
      },
      external_child_workflow_schema.fetch("properties")
    )
  end

  def payload_branch_requiring(required_key)
    schema.fetch("oneOf").find { |branch| branch.fetch("required").include?(required_key) }.tap do |branch|
      refute_nil branch, "Expected payload schema branch requiring #{required_key.inspect}"
    end
  end
end
