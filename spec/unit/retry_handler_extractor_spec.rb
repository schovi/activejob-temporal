# frozen_string_literal: true

require "spec_helper"
require "active_support/core_ext/numeric/time"
require_relative "../fixtures/sample_jobs"

describe ActiveJob::Temporal::RetryHandlerExtractor do
  let(:extractor) { described_class.new }

  describe "#retry_handlers" do
    it "extracts retry handlers from job class" do
      handlers = extractor.retry_handlers(RetryableJob)

      assert_equal 1, handlers.size
      assert_equal SampleJobError, handlers.first[:exception]
      assert_equal 60.seconds, handlers.first[:wait]
      assert_equal 5, handlers.first[:attempts]
      assert_equal "[SampleJobError]", handlers.first[:exception_execution_key]
    end

    it "memoizes retry handler extraction per job class" do
      original_match_status = ActiveJob::Temporal::ActiveJobHandlerSource.method(:match_status)
      match_status_calls = call_recorded_method(
        ActiveJob::Temporal::ActiveJobHandlerSource,
        :match_status
      ) do |handler, method_name|
        original_match_status.call(handler, method_name)
      end

      2.times { extractor.retry_handlers(RetryableJob) }

      matching_calls = match_status_calls.calls_for(:match_status).select do |call|
        call.arguments.last == :retry_on
      end
      assert_equal 1, matching_calls.size
    end

    it "refreshes memoized retry handlers when the job handlers change" do
      first_handler = handler_with(
        fake_binding(wait: 1.second, attempts: 2),
        active_job_handler_source_location(:retry_on)
      )
      second_handler = handler_with(
        fake_binding(wait: 2.seconds, attempts: 3),
        active_job_handler_source_location(:retry_on)
      )
      rescue_handlers = [[SampleJobError, first_handler]]
      job_class = job_class_with_rescue_handlers { rescue_handlers }

      assert_equal 2, extractor.retry_handlers(job_class).first[:attempts]

      rescue_handlers = [[SampleJobError, second_handler]]

      assert_equal 3, extractor.retry_handlers(job_class).first[:attempts]
    end

    it "extracts multiple retry handlers" do
      handlers = extractor.retry_handlers(MultiRetryJob)

      assert_equal 2, handlers.size
      assert_unordered_equal(
        [StandardError, SecondarySampleError],
        handlers.map { |handler| handler[:exception] }
      )
    end

    it "handles retry_on with unlimited attempts" do
      handlers = extractor.retry_handlers(UnlimitedRetryJob)

      assert_equal 1, handlers.size
      assert_equal :unlimited, handlers.first[:attempts]
    end

    it "handles retry_on with Proc wait strategy" do
      handlers = extractor.retry_handlers(ProcWaitRetryJob)

      assert_equal 1, handlers.size
      assert_kind_of Proc, handlers.first[:wait]
    end

    it "handles retry_on with Symbol wait strategy" do
      handlers = extractor.retry_handlers(SymbolWaitRetryJob)

      assert_equal 1, handlers.size
      assert_equal :custom_wait, handlers.first[:wait]
    end

    it "extracts exponentially longer waits as symbol metadata" do
      handlers = extractor.retry_handlers(ExponentiallyLongerRetryJob)

      assert_equal 1, handlers.size
      assert_equal :exponentially_longer, handlers.first[:wait]
      assert_equal 5, handlers.first[:attempts]
    end

    it "extracts polynomially longer waits as symbol metadata" do
      handlers = extractor.retry_handlers(PolynomiallyLongerRetryJob)

      assert_equal 1, handlers.size
      assert_equal :polynomially_longer, handlers.first[:wait]
      assert_equal 6, handlers.first[:attempts]
    end

    it "extracts handlers with invalid attempts values" do
      handlers = extractor.retry_handlers(InvalidAttemptsJob)

      assert_equal 1, handlers.size
      assert_equal "five", handlers.first[:attempts]
    end

    it "falls back to available metadata when ActiveJob retry handler locals change" do
      warning_calls = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      handler_binding = fake_binding(wait: 12.seconds)
      handler = handler_with(handler_binding, active_job_handler_source_location(:retry_on))
      job_class = job_class_with_rescue_handlers([[SampleJobError, handler]])

      handlers = extractor.retry_handlers(job_class)

      assert_equal 1, handlers.size
      assert_hash_includes({ exception: SampleJobError, wait: 12.seconds }, handlers.first)
      assert handlers.first.key?(:attempts), "Expected retry handler to include :attempts"
      assert_nil handlers.first[:attempts]
      assert_warning_logged(
        warning_calls,
        "active_job_handler_metadata_fallback",
        handler_type: "retry",
        job_class: "FallbackRetryJob",
        exception: "SampleJobError"
      )
    end

    it "falls back to default metadata when ActiveJob retry handler binding access fails" do
      handler_binding = binding_that_raises_on_local_lookup
      warning_calls = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      handler = handler_with(handler_binding, active_job_handler_source_location(:retry_on))
      job_class = job_class_with_rescue_handlers([[SampleJobError, handler]])

      handlers = extractor.retry_handlers(job_class)

      assert_equal 1, handlers.size
      assert_hash_includes({ exception: SampleJobError }, handlers.first)
      assert handlers.first.key?(:wait), "Expected retry handler to include :wait"
      assert_nil handlers.first[:wait]
      assert handlers.first.key?(:attempts), "Expected retry handler to include :attempts"
      assert_nil handlers.first[:attempts]
      assert_warning_logged(
        warning_calls,
        "active_job_handler_metadata_fallback",
        handler_type: "retry",
        job_class: "FallbackRetryJob",
        exception: "SampleJobError"
      )
    end

    it "logs an explicit warning when ActiveJob retry handler source is unsupported" do
      warning_calls = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      supported_calls = call_recorded_method(
        ActiveJob::Temporal::ActiveJobHandlerSource,
        :supported?,
        returns: false
      )

      assert_empty extractor.retry_handlers(RetryableJob)
      assert_supported_checked_for(supported_calls, :retry_on)

      assert_warning_logged(
        warning_calls,
        "active_job_handler_source_unavailable",
        handler_type: "retry",
        job_class: "RetryableJob"
      )
    end

    it "logs an explicit warning when retry handler source metadata is unusable" do
      warning_calls = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      handler = handler_with(fake_binding(wait: 1.second, attempts: 2), nil)
      job_class = job_class_with_rescue_handlers([[SampleJobError, handler]])

      assert_empty extractor.retry_handlers(job_class)

      assert_warning_logged(
        warning_calls,
        "active_job_handler_source_unavailable",
        handler_type: "retry",
        job_class: "FallbackRetryJob"
      )
    end

    it "constantizes handler names when defined outside the job class" do
      handlers = extractor.retry_handlers(ExternalConstantRetryJob)

      assert_equal 1, handlers.size
      assert_equal NetworkTimeoutError, handlers.first[:exception]
      assert_equal 15.seconds, handlers.first[:wait]
      assert_equal 2, handlers.first[:attempts]
    end

    it "excludes discard_on handlers" do
      handlers = extractor.retry_handlers(DiscardableJob)

      exceptions = handlers.map { |handler| handler[:exception] }
      assert_equal [SampleJobError], exceptions
      refute_includes exceptions, FatalJobError
    end

    it "returns empty array for job class with no retry_on" do
      handlers = extractor.retry_handlers(SimpleJob)

      assert_empty handlers
    end

    it "returns empty array for job class with only discard_on" do
      handlers = extractor.retry_handlers(DiscardOnlyJob)

      assert_empty handlers
    end

    it "returns empty array for nil job class" do
      handlers = extractor.retry_handlers(nil)

      assert_empty handlers
    end
  end

  describe "#discard_handlers" do
    it "extracts discard handlers from job class" do
      handlers = extractor.discard_handlers(DiscardableJob)

      assert_equal 1, handlers.size
      assert_equal FatalJobError, handlers.first[:exception]
    end

    it "memoizes discard handler extraction per job class" do
      original_match_status = ActiveJob::Temporal::ActiveJobHandlerSource.method(:match_status)
      match_status_calls = call_recorded_method(
        ActiveJob::Temporal::ActiveJobHandlerSource,
        :match_status
      ) do |handler, method_name|
        original_match_status.call(handler, method_name)
      end

      2.times { extractor.discard_handlers(DiscardableJob) }

      matching_calls = match_status_calls.calls_for(:match_status).select do |call|
        call.arguments.last == :discard_on
      end
      assert_equal 2, matching_calls.size
    end

    it "extracts discard handlers from discard-only job" do
      handlers = extractor.discard_handlers(DiscardOnlyJob)

      assert_equal 1, handlers.size
      assert_equal FatalJobError, handlers.first[:exception]
    end

    it "excludes retry_on handlers" do
      handlers = extractor.discard_handlers(DiscardableJob)

      exceptions = handlers.map { |handler| handler[:exception] }
      assert_equal [FatalJobError], exceptions
      refute_includes exceptions, SampleJobError
    end

    it "falls back to source location when ActiveJob discard handler locals change" do
      warning_calls = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      handler = handler_with(fake_binding, active_job_handler_source_location(:discard_on))
      job_class = job_class_with_rescue_handlers([[FatalJobError, handler]])

      handlers = extractor.discard_handlers(job_class)

      assert_equal 1, handlers.size
      assert_hash_includes({ exception: FatalJobError }, handlers.first)
      assert_warning_logged(
        warning_calls,
        "active_job_handler_metadata_fallback",
        handler_type: "discard",
        job_class: "FallbackRetryJob",
        exception: "FatalJobError"
      )
    end

    it "logs an explicit warning when ActiveJob discard handler source is unsupported" do
      warning_calls = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      supported_calls = call_recorded_method(
        ActiveJob::Temporal::ActiveJobHandlerSource,
        :supported?,
        returns: false
      )

      assert_empty extractor.discard_handlers(DiscardableJob)
      assert_supported_checked_for(supported_calls, :discard_on)

      assert_warning_logged(
        warning_calls,
        "active_job_handler_source_unavailable",
        handler_type: "discard",
        job_class: "DiscardableJob"
      )
    end

    it "logs an explicit warning when discard handler source metadata is unusable" do
      warning_calls = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      handler = handler_with(fake_binding(report: true), nil)
      job_class = job_class_with_rescue_handlers([[FatalJobError, handler]])

      assert_empty extractor.discard_handlers(job_class)

      assert_warning_logged(
        warning_calls,
        "active_job_handler_source_unavailable",
        handler_type: "discard",
        job_class: "FallbackRetryJob"
      )
    end

    it "does not classify custom rescue handlers as retry or discard fallbacks" do
      warning_calls = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      handler = handler_with(fake_binding, [__FILE__, __LINE__])
      job_class = job_class_with_rescue_handlers([[SampleJobError, handler]])

      assert_empty extractor.retry_handlers(job_class)
      assert_empty extractor.discard_handlers(job_class)
      assert_empty warning_calls.calls_for(:warn)
    end

    it "does not classify custom rescue handlers that capture retry-like locals" do
      warning_calls = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      handler = handler_with(fake_binding(wait: 3.seconds, attempts: 4), [__FILE__, __LINE__])
      job_class = job_class_with_rescue_handlers([[SampleJobError, handler]])

      assert_empty extractor.retry_handlers(job_class)
      assert_empty warning_calls.calls_for(:warn)
    end

    it "does not classify custom rescue handlers that capture discard-like locals" do
      warning_calls = call_recorded_method(ActiveJob::Temporal::Logger, :warn)
      handler = handler_with(fake_binding(report: true), [__FILE__, __LINE__])
      job_class = job_class_with_rescue_handlers([[FatalJobError, handler]])

      assert_empty extractor.discard_handlers(job_class)
      assert_empty warning_calls.calls_for(:warn)
    end

    it "returns empty array for job class with no discard_on" do
      handlers = extractor.discard_handlers(RetryableJob)

      assert_empty handlers
    end

    it "returns empty array for nil job class" do
      handlers = extractor.discard_handlers(nil)

      assert_empty handlers
    end
  end

  describe "#discard_exception?" do
    it "returns true for discard_on exceptions" do
      assert_equal true, extractor.discard_exception?(DiscardableJob, FatalJobError.new("fatal"))
    end

    it "returns true for subclasses of discard_on exceptions" do
      assert_equal true, extractor.discard_exception?(DiscardableJob, DerivedFatalJobError.new("fatal"))
    end

    it "returns false when the job does not declare discard_on" do
      assert_equal false, extractor.discard_exception?(RetryableJob, FatalJobError.new("fatal"))
    end

    it "returns false for unrelated exceptions" do
      assert_equal false, extractor.discard_exception?(DiscardableJob, StandardError.new("boom"))
    end

    it "returns false when job_class is nil" do
      assert_equal false, extractor.discard_exception?(nil, FatalJobError.new("fatal"))
    end

    it "returns false when exception is nil" do
      assert_equal false, extractor.discard_exception?(DiscardableJob, nil)
    end
  end

  def active_job_handler_source_location(method_name)
    ActiveJob::Exceptions::ClassMethods.instance_method(method_name).source_location
  end

  def fake_binding(variables = {})
    Object.new.tap do |handler_binding|
      handler_binding.define_singleton_method(:local_variable_defined?) do |name|
        variables.key?(name)
      end
      handler_binding.define_singleton_method(:local_variable_get) do |name|
        variables.fetch(name)
      end
    end
  end

  def binding_that_raises_on_local_lookup
    Object.new.tap do |handler_binding|
      handler_binding.define_singleton_method(:local_variable_defined?) do |_name|
        raise NameError, "attempts"
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

  def job_class_with_rescue_handlers(rescue_handlers = nil, &rescue_handlers_block)
    Class.new.tap do |job_class|
      rescue_handlers_source = rescue_handlers_block || proc { rescue_handlers }

      job_class.define_singleton_method(:name) { "FallbackRetryJob" }
      job_class.define_singleton_method(:rescue_handlers, &rescue_handlers_source)
    end
  end

  def assert_warning_logged(warning_calls, event_name, expected_metadata)
    matching_call = warning_calls.calls_for(:warn).find do |call|
      call.arguments == [event_name] && expected_metadata.all? { |key, value| call.keywords[key] == value }
    end

    assert matching_call,
           "Expected #{event_name.inspect} warning with #{expected_metadata.inspect}, " \
           "got #{warning_calls.calls_for(:warn).inspect}"
  end

  def assert_supported_checked_for(supported_calls, method_name)
    calls = supported_calls.calls_for(:supported?)

    refute_empty calls
    assert calls.all? { |call| call.arguments == [method_name] },
           "Expected supported? to be checked only for #{method_name.inspect}, got #{calls.inspect}"
  end
end
