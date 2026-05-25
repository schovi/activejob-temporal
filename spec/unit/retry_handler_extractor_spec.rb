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
      expect(handlers.first[:exception_execution_key]).to eq("[SampleJobError]")
    end

    it "memoizes retry handler extraction per job class" do
      allow(ActiveJob::Temporal::ActiveJobHandlerSource).to receive(:match_status).and_call_original

      2.times { extractor.retry_handlers(RetryableJob) }

      expect(ActiveJob::Temporal::ActiveJobHandlerSource).to have_received(:match_status)
        .with(anything, :retry_on)
        .once
    end

    it "refreshes memoized retry handlers when the job handlers change" do
      first_handler = handler_with(
        binding_double(wait: 1.second, attempts: 2),
        active_job_handler_source_location(:retry_on)
      )
      second_handler = handler_with(
        binding_double(wait: 2.seconds, attempts: 3),
        active_job_handler_source_location(:retry_on)
      )
      rescue_handlers = [[SampleJobError, first_handler]]
      job_class = job_class_with_rescue_handlers { rescue_handlers }

      expect(extractor.retry_handlers(job_class).first[:attempts]).to eq(2)

      rescue_handlers = [[SampleJobError, second_handler]]

      expect(extractor.retry_handlers(job_class).first[:attempts]).to eq(3)
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

    it "extracts exponentially longer waits as symbol metadata" do
      handlers = extractor.retry_handlers(ExponentiallyLongerRetryJob)

      expect(handlers.size).to eq(1)
      expect(handlers.first[:wait]).to eq(:exponentially_longer)
      expect(handlers.first[:attempts]).to eq(5)
    end

    it "extracts polynomially longer waits as symbol metadata" do
      handlers = extractor.retry_handlers(PolynomiallyLongerRetryJob)

      expect(handlers.size).to eq(1)
      expect(handlers.first[:wait]).to eq(:polynomially_longer)
      expect(handlers.first[:attempts]).to eq(6)
    end

    it "extracts handlers with invalid attempts values" do
      handlers = extractor.retry_handlers(InvalidAttemptsJob)

      expect(handlers.size).to eq(1)
      expect(handlers.first[:attempts]).to eq("five")
    end

    it "falls back to available metadata when ActiveJob retry handler locals change" do
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      handler_binding = binding_double(wait: 12.seconds)
      handler = handler_with(handler_binding, active_job_handler_source_location(:retry_on))
      job_class = job_class_with_rescue_handlers([[SampleJobError, handler]])

      handlers = extractor.retry_handlers(job_class)

      expect(handlers).to contain_exactly(
        hash_including(exception: SampleJobError, wait: 12.seconds, attempts: nil)
      )
      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "active_job_handler_metadata_fallback",
        hash_including(handler_type: "retry", job_class: "FallbackRetryJob", exception: "SampleJobError")
      )
    end

    it "falls back to default metadata when ActiveJob retry handler binding access fails" do
      handler_binding = instance_double(Binding)
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      allow(handler_binding).to receive(:local_variable_defined?).and_raise(NameError, "attempts")
      handler = handler_with(handler_binding, active_job_handler_source_location(:retry_on))
      job_class = job_class_with_rescue_handlers([[SampleJobError, handler]])

      handlers = extractor.retry_handlers(job_class)

      expect(handlers).to contain_exactly(
        hash_including(exception: SampleJobError, wait: nil, attempts: nil)
      )
      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "active_job_handler_metadata_fallback",
        hash_including(handler_type: "retry", job_class: "FallbackRetryJob", exception: "SampleJobError")
      )
    end

    it "logs an explicit warning when ActiveJob retry handler source is unsupported" do
      allow(ActiveJob::Temporal::ActiveJobHandlerSource).to receive(:supported?)
        .with(:retry_on)
        .and_return(false)
      allow(ActiveJob::Temporal::Logger).to receive(:warn)

      expect(extractor.retry_handlers(RetryableJob)).to be_empty

      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "active_job_handler_source_unavailable",
        hash_including(handler_type: "retry", job_class: "RetryableJob")
      )
    end

    it "logs an explicit warning when retry handler source metadata is unusable" do
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      handler = handler_with(binding_double(wait: 1.second, attempts: 2), nil)
      job_class = job_class_with_rescue_handlers([[SampleJobError, handler]])

      expect(extractor.retry_handlers(job_class)).to be_empty

      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "active_job_handler_source_unavailable",
        hash_including(handler_type: "retry", job_class: "FallbackRetryJob")
      )
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

    it "memoizes discard handler extraction per job class" do
      allow(ActiveJob::Temporal::ActiveJobHandlerSource).to receive(:match_status).and_call_original

      2.times { extractor.discard_handlers(DiscardableJob) }

      expect(ActiveJob::Temporal::ActiveJobHandlerSource).to have_received(:match_status)
        .with(anything, :discard_on)
        .twice
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

    it "falls back to source location when ActiveJob discard handler locals change" do
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      handler = handler_with(binding_double, active_job_handler_source_location(:discard_on))
      job_class = job_class_with_rescue_handlers([[FatalJobError, handler]])

      handlers = extractor.discard_handlers(job_class)

      expect(handlers).to contain_exactly(
        hash_including(exception: FatalJobError)
      )
      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "active_job_handler_metadata_fallback",
        hash_including(handler_type: "discard", job_class: "FallbackRetryJob", exception: "FatalJobError")
      )
    end

    it "logs an explicit warning when ActiveJob discard handler source is unsupported" do
      allow(ActiveJob::Temporal::ActiveJobHandlerSource).to receive(:supported?)
        .with(:discard_on)
        .and_return(false)
      allow(ActiveJob::Temporal::Logger).to receive(:warn)

      expect(extractor.discard_handlers(DiscardableJob)).to be_empty

      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "active_job_handler_source_unavailable",
        hash_including(handler_type: "discard", job_class: "DiscardableJob")
      )
    end

    it "logs an explicit warning when discard handler source metadata is unusable" do
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      handler = handler_with(binding_double(report: true), nil)
      job_class = job_class_with_rescue_handlers([[FatalJobError, handler]])

      expect(extractor.discard_handlers(job_class)).to be_empty

      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "active_job_handler_source_unavailable",
        hash_including(handler_type: "discard", job_class: "FallbackRetryJob")
      )
    end

    it "does not classify custom rescue handlers as retry or discard fallbacks" do
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      handler = handler_with(binding_double, [__FILE__, __LINE__])
      job_class = job_class_with_rescue_handlers([[SampleJobError, handler]])

      expect(extractor.retry_handlers(job_class)).to be_empty
      expect(extractor.discard_handlers(job_class)).to be_empty
      expect(ActiveJob::Temporal::Logger).not_to have_received(:warn)
    end

    it "does not classify custom rescue handlers that capture retry-like locals" do
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      handler = handler_with(binding_double(wait: 3.seconds, attempts: 4), [__FILE__, __LINE__])
      job_class = job_class_with_rescue_handlers([[SampleJobError, handler]])

      expect(extractor.retry_handlers(job_class)).to be_empty
      expect(ActiveJob::Temporal::Logger).not_to have_received(:warn)
    end

    it "does not classify custom rescue handlers that capture discard-like locals" do
      allow(ActiveJob::Temporal::Logger).to receive(:warn)
      handler = handler_with(binding_double(report: true), [__FILE__, __LINE__])
      job_class = job_class_with_rescue_handlers([[FatalJobError, handler]])

      expect(extractor.discard_handlers(job_class)).to be_empty
      expect(ActiveJob::Temporal::Logger).not_to have_received(:warn)
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

  def active_job_handler_source_location(method_name)
    ActiveJob::Exceptions::ClassMethods.instance_method(method_name).source_location
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

  def job_class_with_rescue_handlers(rescue_handlers = nil, &rescue_handlers_block)
    Class.new.tap do |job_class|
      rescue_handlers_source = rescue_handlers_block || proc { rescue_handlers }

      job_class.define_singleton_method(:name) { "FallbackRetryJob" }
      job_class.define_singleton_method(:rescue_handlers, &rescue_handlers_source)
    end
  end
end
