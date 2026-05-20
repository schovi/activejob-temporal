# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Worker configuration", :integration do
  describe "activity concurrency" do
    it "uses ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES environment variable" do
      skip "Manual verification: ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES=50 bin/temporal-worker"
    end
  end

  describe "workflow concurrency" do
    it "uses ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS environment variable" do
      skip "Manual verification: ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS=50 bin/temporal-worker"
    end

    it "defaults to 5 when environment variable is not set" do
      skip "Manual verification: Check worker logs show max_concurrent_workflows: 5"
    end
  end

  describe "combined configuration" do
    it "supports both activity and workflow concurrency settings" do
      skip "Manual verification: See docs/worker_setup.md"
    end
  end
end
