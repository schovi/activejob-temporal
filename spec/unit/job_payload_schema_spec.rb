# frozen_string_literal: true

require "json"
require "spec_helper"

RSpec.describe "job payload schema" do
  let(:schema) { JSON.parse(File.read("api/job_payload_schema.json")) }

  it "allows workflow-control metadata for all payload formats" do
    payload_branches = schema.fetch("oneOf")

    expect(payload_branches).to all(
      include(
        "properties" => include(
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
          "activity_task_queue" => { "type" => "string", "minLength" => 1 }
        )
      )
    )
  end

  it "defines workflow interaction metadata" do
    interaction_schema = schema.fetch("definitions").fetch("workflow_interactions")

    expect(interaction_schema).to include(
      "type" => "object",
      "additionalProperties" => false,
      "required" => contain_exactly("job_class", "signals", "queries", "updates"),
      "properties" => include(
        "job_class" => { "type" => "string", "minLength" => 1 },
        "signals" => include("type" => "array", "uniqueItems" => true),
        "queries" => include("type" => "array", "uniqueItems" => true),
        "updates" => include("type" => "array", "uniqueItems" => true)
      )
    )
  end

  it "defines workflow identity metadata" do
    identity_schema = schema.fetch("definitions").fetch("workflow_identity")

    expect(identity_schema).to include(
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["workflow_name"],
      "properties" => include(
        "workflow_name" => { "type" => "string", "minLength" => 1 },
        "workflow_id_prefix" => { "type" => "string", "minLength" => 1 }
      )
    )
  end

  it "allows serialized payload envelopes" do
    serialized_branch = schema.fetch("oneOf").find do |branch|
      branch.fetch("required").include?("serialized_payload")
    end

    expect(serialized_branch).to include(
      "required" => contain_exactly(
        "serialized_payload",
        "payload_serializer",
        "payload_serializer_version",
        "serialized_data"
      ),
      "properties" => include(
        "payload_serializer" => { "type" => "string", "enum" => %w[message_pack marshal] },
        "payload_serializer_version" => { "type" => "integer", "enum" => [1] },
        "serialized_data" => { "type" => "string" }
      )
    )
  end

  it "allows serializer metadata on encrypted payloads" do
    encrypted_branch = schema.fetch("oneOf").find do |branch|
      branch.fetch("required").include?("encrypted_payload")
    end

    expect(encrypted_branch).to include(
      "dependencies" => {
        "payload_serializer" => ["payload_serializer_version"],
        "payload_serializer_version" => ["payload_serializer"]
      }
    )
    expect(encrypted_branch.fetch("properties")).to include(
      "payload_serializer" => { "type" => "string", "enum" => %w[message_pack marshal] },
      "payload_serializer_version" => { "type" => "integer", "enum" => [1] }
    )
  end

  it "allows v2 encrypted payload metadata" do
    encrypted_branch = schema.fetch("oneOf").find do |branch|
      branch.fetch("required").include?("encrypted_payload")
    end

    expect(encrypted_branch.fetch("properties")).to include(
      "encrypted_payload_version" => { "type" => "integer", "enum" => [1, 2] },
      "encrypted_key_id" => { "type" => "string", "minLength" => 1 },
      "encrypted_iv" => { "type" => "string" },
      "encrypted_auth_tag" => { "type" => "string" }
    )
  end

  it "allows external payload envelopes" do
    external_branch = schema.fetch("oneOf").find do |branch|
      branch.fetch("required").include?("external_payload")
    end

    expect(external_branch).to include(
      "required" => contain_exactly(
        "external_payload",
        "external_payload_version",
        "external_payload_reference"
      ),
      "properties" => include(
        "external_payload" => { "const" => true },
        "external_payload_version" => { "type" => "integer", "enum" => [1] },
        "external_payload_reference" => {}
      )
    )
  end

  it "requires normalized rate limit entries" do
    rate_limit_schema = schema.fetch("definitions").fetch("rate_limit")

    expect(rate_limit_schema.fetch("required")).to contain_exactly("limit", "interval", "key")
    expect(rate_limit_schema.fetch("additionalProperties")).to be(false)
  end

  it "defines dependency metadata" do
    dependency_schema = schema.fetch("definitions").fetch("dependency")

    expect(dependency_schema).to include(
      "type" => "object",
      "additionalProperties" => false,
      "anyOf" => contain_exactly(
        { "required" => ["job_id"] },
        { "required" => ["workflow_id"] }
      ),
      "properties" => include(
        "job_class" => { "type" => "string", "minLength" => 1 },
        "job_id" => { "type" => "string", "minLength" => 1 },
        "workflow_id" => { "type" => "string", "minLength" => 1 }
      )
    )
  end

  it "defines child workflow metadata" do
    child_workflow_schema = schema.fetch("definitions").fetch("active_job_child_workflow")

    expect(child_workflow_schema).to include(
      "type" => "object",
      "additionalProperties" => false,
      "required" => contain_exactly("job_class", "job_id", "workflow_id", "queue_name", "arguments"),
      "properties" => include(
        "job_class" => { "type" => "string", "minLength" => 1 },
        "job_id" => { "type" => "string", "minLength" => 1 },
        "workflow_id" => { "type" => "string", "minLength" => 1 },
        "workflow_task_queue" => { "type" => "string", "minLength" => 1 },
        "search_attributes" => { "$ref" => "#/definitions/child_workflow_search_attributes" }
      )
    )
  end

  it "defines external Temporal chain step metadata" do
    external_chain_step_schema = schema.fetch("definitions").fetch("external_chain_step")

    expect(external_chain_step_schema).to include(
      "type" => "object",
      "additionalProperties" => false,
      "required" => contain_exactly("temporal_operation", "temporal_type", "options"),
      "properties" => include(
        "temporal_operation" => { "type" => "string", "enum" => %w[activity workflow] },
        "temporal_type" => { "type" => "string", "minLength" => 1 },
        "options" => { "$ref" => "#/definitions/external_temporal_options" }
      )
    )
  end

  it "defines external Temporal child workflow metadata" do
    external_child_workflow_schema = schema.fetch("definitions").fetch("external_child_workflow")

    expect(external_child_workflow_schema).to include(
      "type" => "object",
      "additionalProperties" => false,
      "required" => contain_exactly("temporal_operation", "temporal_type", "options"),
      "properties" => include(
        "temporal_operation" => { "type" => "string", "enum" => ["workflow"] },
        "temporal_type" => { "type" => "string", "minLength" => 1 },
        "options" => { "$ref" => "#/definitions/external_temporal_options" }
      )
    )
  end
end
