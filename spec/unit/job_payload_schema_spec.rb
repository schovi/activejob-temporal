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
          "rate_limits" => { "$ref" => "#/definitions/rate_limits" }
        )
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

  it "requires normalized rate limit entries" do
    rate_limit_schema = schema.fetch("definitions").fetch("rate_limit")

    expect(rate_limit_schema.fetch("required")).to contain_exactly("limit", "interval", "key")
    expect(rate_limit_schema.fetch("additionalProperties")).to be(false)
  end
end
