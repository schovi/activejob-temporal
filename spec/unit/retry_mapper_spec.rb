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

    it "maps :unlimited attempts to zero maximum_attempts" do
      policy = described_class.for(UnlimitedRetryJob)

      expect(policy[:maximum_attempts]).to eq(0)
    end

    it "falls back to default interval for Proc wait values" do
      policy = described_class.for(ProcWaitRetryJob)

      expect(policy[:initial_interval]).to eq(30)
    end

    it "falls back to default interval for Symbol wait values" do
      policy = described_class.for(SymbolWaitRetryJob)

      expect(policy[:initial_interval]).to eq(30)
    end

    it "uses default attempts when the job declares a non-numeric value" do
      expect(ActiveJob::Temporal::Logger).to receive(:warn).with(
        "retry_attempts_fallback",
        job_class: "InvalidAttemptsJob",
        attempts: "\"five\"",
        default_attempts: 1,
        error_class: "ArgumentError"
      )

      policy = described_class.for(InvalidAttemptsJob)

      expect(policy[:maximum_attempts]).to eq(1)
    end

    it "uses configured defaults when ActiveJob retry metadata falls back" do
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      handler = handler_with(failing_binding, active_job_handler_source_location(:retry_on))
      job_class = job_class_with_rescue_handlers([[SampleJobError, handler]])

      policy = described_class.for(job_class)

      expect(policy).to include(
        initial_interval: 30,
        maximum_attempts: 1
      )
    end

    it "collects discard handlers when ActiveJob discard metadata falls back" do
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      handler = handler_with(binding_double, active_job_handler_source_location(:discard_on))
      job_class = job_class_with_rescue_handlers([[FatalJobError, handler]])

      policy = described_class.for(job_class)

      expect(policy[:non_retryable_error_types]).to eq(["FatalJobError"])
    end

    it "constantizes handler names when defined outside the job class" do
      policy = described_class.for(ExternalConstantRetryJob, NetworkTimeoutError.new("boom"))

      expect(policy[:initial_interval]).to eq(15)
      expect(policy[:maximum_attempts]).to eq(2)
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

    it "returns false when exception is nil" do
      expect(described_class.discard_exception?(DiscardableJob, nil)).to be(false)
    end
  end

  def active_job_handler_source_location(method_name)
    ActiveJob::Exceptions::ClassMethods.instance_method(method_name).source_location
  end

  def failing_binding
    instance_double(Binding).tap do |handler_binding|
      allow(handler_binding).to receive(:local_variable_defined?).and_raise(NameError, "attempts")
    end
  end

  def binding_double(variables = {})
    instance_double(Binding).tap do |handler_binding|
      allow(handler_binding).to receive(:local_variable_defined?) do |name|
        variables.key?(name)
      end
      allow(handler_binding).to receive(:local_variable_get) do |name|
        variables.fetch(name)
      end
    end
  end

  def handler_with(handler_binding, source_location)
    Struct.new(:handler_binding, :source_location) do
      def binding
        handler_binding
      end
    end.new(handler_binding, source_location)
  end

  def job_class_with_rescue_handlers(rescue_handlers)
    Class.new.tap do |job_class|
      job_class.define_singleton_method(:name) { "FallbackRetryMapperJob" }
      job_class.define_singleton_method(:rescue_handlers) { rescue_handlers }
    end
  end
end
