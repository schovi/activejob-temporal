# frozen_string_literal: true

require "spec_helper"
require "active_support/core_ext/numeric/time"
require_relative "../fixtures/sample_jobs"

module RetryMapperSpecSupport
  class FakeBinding
    def initialize(variables: {}, local_variable_defined_error: nil)
      @variables = variables
      @local_variable_defined_error = local_variable_defined_error
    end

    def local_variable_defined?(name)
      raise @local_variable_defined_error if @local_variable_defined_error

      @variables.key?(name)
    end

    def local_variable_get(name)
      @variables.fetch(name)
    end
  end
end

describe ActiveJob::Temporal::RetryMapper do
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

      assert_equal(
        {
          initial_interval: 30,
          backoff_coefficient: 2.0,
          maximum_attempts: 1,
          non_retryable_error_types: []
        },
        policy
      )
    end

    it "maps retry_on wait and attempts to Temporal retry fields" do
      policy = described_class.for(RetryableJob)

      assert_hash_includes(
        {
          initial_interval: 60,
          backoff_coefficient: 2.0,
          maximum_attempts: 5,
          non_retryable_error_types: []
        },
        policy
      )
    end

    it "prefers the most specific retry_on handler when no exception is provided" do
      policy = described_class.for(MultiRetryJob)

      assert_hash_includes({ initial_interval: 10, maximum_attempts: 6 }, policy)
    end

    it "selects the retry configuration for the provided exception class" do
      policy = described_class.for(MultiRetryJob, StandardError.new("boom"))

      assert_hash_includes({ initial_interval: 40, maximum_attempts: 2 }, policy)
    end

    it "collects discard_on declarations as non_retryable_error_types" do
      policy = described_class.for(DiscardableJob)

      assert_equal ["FatalJobError"], policy[:non_retryable_error_types]
    end

    it "uses defaults for jobs that only declare discard_on" do
      policy = described_class.for(DiscardOnlyJob)

      assert_hash_includes(
        { initial_interval: 30, maximum_attempts: 1, non_retryable_error_types: ["FatalJobError"] },
        policy
      )
    end

    it "maps :unlimited attempts to zero maximum_attempts" do
      policy = described_class.for(UnlimitedRetryJob)

      assert_equal 0, policy[:maximum_attempts]
    end

    it "falls back to default interval for Proc wait values" do
      policy = described_class.for(ProcWaitRetryJob)

      assert_equal 30, policy[:initial_interval]
    end

    it "falls back to default interval for Symbol wait values" do
      policy = described_class.for(SymbolWaitRetryJob)

      assert_equal 30, policy[:initial_interval]
    end

    it "falls back to numeric Temporal settings for exponentially longer waits" do
      policy = described_class.for(ExponentiallyLongerRetryJob)

      assert_hash_includes({ initial_interval: 30, backoff_coefficient: 2.0, maximum_attempts: 5 }, policy)
    end

    it "falls back to numeric Temporal settings for polynomially longer waits" do
      policy = described_class.for(PolynomiallyLongerRetryJob)

      assert_hash_includes({ initial_interval: 30, backoff_coefficient: 2.0, maximum_attempts: 6 }, policy)
    end

    it "uses default attempts when the job declares a non-numeric value" do
      warning_calls = call_recorded_method(ActiveJob::Temporal::Logger, :warn)

      policy = described_class.for(InvalidAttemptsJob)

      warning_call = warning_calls.calls_for(:warn).first
      assert_equal ["retry_attempts_fallback"], warning_call.arguments
      assert_equal(
        {
          job_class: "InvalidAttemptsJob",
          attempts: "\"five\"",
          default_attempts: 1,
          error_class: "ArgumentError"
        },
        warning_call.keywords
      )
      assert_equal 1, policy[:maximum_attempts]
    end

    it "uses configured defaults when ActiveJob retry metadata falls back" do
      call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      handler = handler_with(failing_binding, active_job_handler_source_location(:retry_on))
      job_class = job_class_with_rescue_handlers([[SampleJobError, handler]])

      policy = described_class.for(job_class)

      assert_hash_includes({ initial_interval: 30, maximum_attempts: 1 }, policy)
    end

    it "collects discard handlers when ActiveJob discard metadata falls back" do
      call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      handler = handler_with(fake_binding, active_job_handler_source_location(:discard_on))
      job_class = job_class_with_rescue_handlers([[FatalJobError, handler]])

      policy = described_class.for(job_class)

      assert_equal ["FatalJobError"], policy[:non_retryable_error_types]
    end

    it "constantizes handler names when defined outside the job class" do
      policy = described_class.for(ExternalConstantRetryJob, NetworkTimeoutError.new("boom"))

      assert_equal 15, policy[:initial_interval]
      assert_equal 2, policy[:maximum_attempts]
    end

    it "reuses extracted handler metadata across policy builds" do
      described_class.remove_instance_variable(:@extractor) if described_class.instance_variable_defined?(:@extractor)
      described_class.for(RetryableJob)
      original_readlines = File.method(:readlines)
      readlines_calls = call_recorded_method(File, :readlines) do |*arguments, **keywords|
        original_readlines.call(*arguments, **keywords)
      end

      described_class.for(RetryableJob)

      assert_empty readlines_calls.calls_for(:readlines)
    end
  end

  describe ".discard_exception?" do
    it "returns true for discard_on exceptions" do
      assert_equal true, described_class.discard_exception?(DiscardableJob, FatalJobError.new("fatal"))
    end

    it "returns true for subclasses of discard_on exceptions" do
      assert_equal true, described_class.discard_exception?(DiscardableJob, DerivedFatalJobError.new("fatal"))
    end

    it "returns false when the job does not declare discard_on" do
      assert_equal false, described_class.discard_exception?(RetryableJob, FatalJobError.new("fatal"))
    end

    it "returns false for unrelated exceptions" do
      assert_equal false, described_class.discard_exception?(DiscardableJob, StandardError.new("boom"))
    end

    it "returns false when job_class is nil" do
      assert_equal false, described_class.discard_exception?(nil, FatalJobError.new("fatal"))
    end

    it "returns false when exception is nil" do
      assert_equal false, described_class.discard_exception?(DiscardableJob, nil)
    end
  end

  describe ".exception_execution_keys" do
    it "returns ActiveJob exception execution keys for retry handlers" do
      assert_unordered_equal(
        [
          "[SecondarySampleError]",
          "[StandardError]"
        ],
        described_class.exception_execution_keys(MultiRetryJob)
      )
    end
  end

  def active_job_handler_source_location(method_name)
    ActiveJob::Exceptions::ClassMethods.instance_method(method_name).source_location
  end

  def failing_binding
    RetryMapperSpecSupport::FakeBinding.new(local_variable_defined_error: NameError.new("attempts"))
  end

  def fake_binding(variables = {})
    RetryMapperSpecSupport::FakeBinding.new(variables: variables)
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
