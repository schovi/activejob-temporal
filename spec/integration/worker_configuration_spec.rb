# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Worker configuration", :integration do
  describe "activity concurrency" do
    it "uses AJ_TEMPORAL_MAX_ACT environment variable" do
      # This is an integration/manual test
      # Can't easily test subprocess configuration
      # Best verified by running worker and checking logs
      pending "Manual verification: AJ_TEMPORAL_MAX_ACT=50 bin/temporal-worker"
    end
  end

  describe "workflow concurrency" do
    it "uses AJ_TEMPORAL_MAX_WORKFLOWS environment variable" do
      pending "Manual verification: AJ_TEMPORAL_MAX_WORKFLOWS=50 bin/temporal-worker"
    end

    it "defaults to 5 when environment variable is not set" do
      # Default value should be 5 as per Temporal SDK defaults
      pending "Manual verification: Check worker logs show max_concurrent_workflows: 5"
    end
  end

  describe "combined configuration" do
    it "supports both activity and workflow concurrency settings" do
      pending "Manual verification: AJ_TEMPORAL_MAX_ACT=200 AJ_TEMPORAL_MAX_WORKFLOWS=20 bin/temporal-worker"
    end
  end
end
