# frozen_string_literal: true

require "spec_helper"
require "active_support/core_ext/numeric/time"
require_relative "../fixtures/sample_jobs"

RSpec.describe ActiveJob::Temporal::RetryHandlerExtractor do
  let(:extractor) { described_class.new }

  describe "#retry_handlers" do
    it "extracts retry handlers from job class" do
      handlers = extractor.retry_handlers(RetryableJob)

      expect(handlers.size).to eq(1)
      expect(handlers.first[:exception]).to eq(SampleJobError)
      expect(handlers.first[:wait]).to eq(60.seconds)
      expect(handlers.first[:attempts]).to eq(5)
    end

    it "extracts multiple retry handlers" do
      handlers = extractor.retry_handlers(MultiRetryJob)

      expect(handlers.size).to eq(2)
      expect(handlers.map { |h| h[:exception] }).to contain_exactly(
        StandardError, SecondarySampleError
      )
    end

    it "handles retry_on with unlimited attempts" do
      handlers = extractor.retry_handlers(UnlimitedRetryJob)

      expect(handlers.size).to eq(1)
      expect(handlers.first[:attempts]).to eq(:unlimited)
    end

    it "handles retry_on with Proc wait strategy" do
      handlers = extractor.retry_handlers(ProcWaitRetryJob)

      expect(handlers.size).to eq(1)
      expect(handlers.first[:wait]).to be_a(Proc)
    end

    it "handles retry_on with Symbol wait strategy" do
      handlers = extractor.retry_handlers(SymbolWaitRetryJob)

      expect(handlers.size).to eq(1)
      expect(handlers.first[:wait]).to eq(:custom_wait)
    end

    it "extracts handlers with invalid attempts values" do
      handlers = extractor.retry_handlers(InvalidAttemptsJob)

      expect(handlers.size).to eq(1)
      expect(handlers.first[:attempts]).to eq("five")
    end

    it "constantizes handler names when defined outside the job class" do
      handlers = extractor.retry_handlers(ExternalConstantRetryJob)

      expect(handlers.size).to eq(1)
      expect(handlers.first[:exception]).to eq(NetworkTimeoutError)
      expect(handlers.first[:wait]).to eq(15.seconds)
      expect(handlers.first[:attempts]).to eq(2)
    end

    it "excludes discard_on handlers" do
      handlers = extractor.retry_handlers(DiscardableJob)

      expect(handlers.map { |h| h[:exception] }).to eq([SampleJobError])
      expect(handlers.map { |h| h[:exception] }).not_to include(FatalJobError)
    end

    it "returns empty array for job class with no retry_on" do
      handlers = extractor.retry_handlers(SimpleJob)

      expect(handlers).to be_empty
    end

    it "returns empty array for job class with only discard_on" do
      handlers = extractor.retry_handlers(DiscardOnlyJob)

      expect(handlers).to be_empty
    end

    it "returns empty array for nil job class" do
      handlers = extractor.retry_handlers(nil)

      expect(handlers).to be_empty
    end
  end

  describe "#discard_handlers" do
    it "extracts discard handlers from job class" do
      handlers = extractor.discard_handlers(DiscardableJob)

      expect(handlers.size).to eq(1)
      expect(handlers.first[:exception]).to eq(FatalJobError)
    end

    it "extracts discard handlers from discard-only job" do
      handlers = extractor.discard_handlers(DiscardOnlyJob)

      expect(handlers.size).to eq(1)
      expect(handlers.first[:exception]).to eq(FatalJobError)
    end

    it "excludes retry_on handlers" do
      handlers = extractor.discard_handlers(DiscardableJob)

      expect(handlers.map { |h| h[:exception] }).to eq([FatalJobError])
      expect(handlers.map { |h| h[:exception] }).not_to include(SampleJobError)
    end

    it "returns empty array for job class with no discard_on" do
      handlers = extractor.discard_handlers(RetryableJob)

      expect(handlers).to be_empty
    end

    it "returns empty array for nil job class" do
      handlers = extractor.discard_handlers(nil)

      expect(handlers).to be_empty
    end
  end

  describe "#discard_exception?" do
    it "returns true for discard_on exceptions" do
      expect(extractor.discard_exception?(DiscardableJob, FatalJobError.new("fatal")))
        .to be(true)
    end

    it "returns true for subclasses of discard_on exceptions" do
      expect(extractor.discard_exception?(DiscardableJob, DerivedFatalJobError.new("fatal")))
        .to be(true)
    end

    it "returns false when the job does not declare discard_on" do
      expect(extractor.discard_exception?(RetryableJob, FatalJobError.new("fatal")))
        .to be(false)
    end

    it "returns false for unrelated exceptions" do
      expect(extractor.discard_exception?(DiscardableJob, StandardError.new("boom")))
        .to be(false)
    end

    it "returns false when job_class is nil" do
      expect(extractor.discard_exception?(nil, FatalJobError.new("fatal"))).to be(false)
    end

    it "returns false when exception is nil" do
      expect(extractor.discard_exception?(DiscardableJob, nil)).to be(false)
    end
  end
end
