# frozen_string_literal: true

require "spec_helper"
require "active_support/core_ext/numeric/time"
require_relative "../fixtures/sample_jobs"

RSpec.describe ActiveJob::Temporal::RetryMapper do
  before do
    ActiveJob::Temporal.configure do |config|
      config.default_retry_initial_interval = 30.seconds
      config.default_retry_backoff = 2.0
      config.default_retry_max_attempts = 1
    end
  end

  describe ".for" do
    it "returns the default policy when the job has no retry_on or discard_on" do
      policy = described_class.for(SimpleJob)

      expect(policy).to eq(
        initial_interval: 30,
        backoff_coefficient: 2.0,
        maximum_attempts: 1,
        non_retryable_error_types: []
      )
    end

    it "maps retry_on wait and attempts to Temporal retry fields" do
      policy = described_class.for(RetryableJob)

      expect(policy).to include(
        initial_interval: 60,
        backoff_coefficient: 2.0,
        maximum_attempts: 5,
        non_retryable_error_types: []
      )
    end

    it "prefers the most specific retry_on handler when no exception is provided" do
      policy = described_class.for(MultiRetryJob)

      expect(policy).to include(
        initial_interval: 10,
        maximum_attempts: 6
      )
    end

    it "selects the retry configuration for the provided exception class" do
      policy = described_class.for(MultiRetryJob, StandardError.new("boom"))

      expect(policy).to include(
        initial_interval: 40,
        maximum_attempts: 2
      )
    end

    it "collects discard_on declarations as non_retryable_error_types" do
      policy = described_class.for(DiscardableJob)

      expect(policy[:non_retryable_error_types]).to eq(["FatalJobError"])
    end

    it "uses defaults for jobs that only declare discard_on" do
      policy = described_class.for(DiscardOnlyJob)

      expect(policy).to include(
        initial_interval: 30,
        maximum_attempts: 1,
        non_retryable_error_types: ["FatalJobError"]
      )
    end
  end

  describe ".discard_exception?" do
    it "returns true for discard_on exceptions" do
      expect(described_class.discard_exception?(DiscardableJob, FatalJobError.new("fatal")))
        .to be(true)
    end

    it "returns true for subclasses of discard_on exceptions" do
      expect(described_class.discard_exception?(DiscardableJob, DerivedFatalJobError.new("fatal")))
        .to be(true)
    end

    it "returns false when the job does not declare discard_on" do
      expect(described_class.discard_exception?(RetryableJob, FatalJobError.new("fatal")))
        .to be(false)
    end

    it "returns false for unrelated exceptions" do
      expect(described_class.discard_exception?(DiscardableJob, StandardError.new("boom")))
        .to be(false)
    end

    it "returns false when job_class is nil" do
      expect(described_class.discard_exception?(nil, FatalJobError.new("fatal"))).to be(false)
    end
  end
end
