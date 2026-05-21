# frozen_string_literal: true

require "json"
require "spec_helper"

RSpec.describe "job payload schema" do
  let(:schema) { JSON.parse(File.read("api/job_payload_schema.json")) }

  it "allows rate limit metadata for plaintext and encrypted payloads" do
    payload_branches = schema.fetch("oneOf")

    expect(payload_branches).to all(
      include("properties" => include("rate_limits" => { "$ref" => "#/definitions/rate_limits" }))
    )
  end

  it "requires normalized rate limit entries" do
    rate_limit_schema = schema.fetch("definitions").fetch("rate_limit")

    expect(rate_limit_schema.fetch("required")).to contain_exactly("limit", "interval", "key")
    expect(rate_limit_schema.fetch("additionalProperties")).to be(false)
  end
end
