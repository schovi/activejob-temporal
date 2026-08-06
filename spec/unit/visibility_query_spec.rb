# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/visibility_query"

describe ActiveJob::Temporal::VisibilityQuery do
  it "quotes values made of allowlisted characters" do
    assert_equal "'MyApp::SimpleJob'", described_class.quote("MyApp::SimpleJob")
    assert_equal "'550e8400-e29b-41d4-a716-446655440000'",
                 described_class.quote("550e8400-e29b-41d4-a716-446655440000")
    assert_equal "'tenant_42.v1'", described_class.quote("tenant_42.v1")
  end

  it "rejects values containing single quotes" do
    assert_raises(ArgumentError) { described_class.quote("test' OR '1'='1") }
  end

  it "rejects values containing backslashes" do
    assert_raises(ArgumentError) { described_class.quote("tenant\\' OR ajClass!='x") }
  end

  it "rejects blank and whitespace values" do
    assert_raises(ArgumentError) { described_class.quote("") }
    assert_raises(ArgumentError) { described_class.quote(nil) }
    assert_raises(ArgumentError) { described_class.quote("job id") }
  end
end
