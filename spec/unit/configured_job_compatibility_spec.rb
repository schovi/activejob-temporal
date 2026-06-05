# frozen_string_literal: true

require "spec_helper"
require "active_job"

describe ActiveJob::Temporal::ConfiguredJobCompatibility do
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "ConfiguredCompatibilityJob"

      def perform(*) = nil
    end
  end

  def symbolize_options(options)
    options.each_with_object({}) do |(key, value), normalized|
      normalized[key.to_sym] = value
    end
  end

  describe ".payload" do
    it "returns nil for values that are not ActiveJob configured jobs" do
      assert_nil described_class.payload(job_class, feature: "chain", normalize_options: method(:symbolize_options))
    end

    it "extracts configured job class and options through the isolated compatibility layer" do
      logger_warnings = call_recorded_method(ActiveJob::Temporal::Logger, :warn)

      payload = described_class.payload(
        job_class.set(queue: "critical", priority: 7),
        feature: "chain",
        normalize_options: method(:symbolize_options)
      )
      expected_payload = {
        job_class: "ConfiguredCompatibilityJob",
        options: {
          queue: "critical",
          priority: 7
        }
      }

      assert_equal expected_payload, payload
      assert_private_api_warning logger_warnings, feature: "chain", replacement: "ActiveJob::Temporal.job"
    end

    it "fails clearly when ActiveJob moves configured job internals to an untested version" do
      call_recorded_method(described_class, :active_job_version, returns: Gem::Version.new("8.2.0"))

      error = assert_raises(ArgumentError) do
        described_class.payload(
          job_class.set(queue: "critical"),
          feature: "chain",
          normalize_options: method(:symbolize_options)
        )
      end
      assert_match(
        /ActiveJob::ConfiguredJob internals are not supported for chain on ActiveJob 8\.2\.0.*ActiveJob::Temporal\.job/,
        error.message
      )
    end

    it "fails clearly when configured job internals do not expose a job class" do
      configured_job = ActiveJob::ConfiguredJob.allocate

      error = assert_raises(ArgumentError) do
        described_class.payload(
          configured_job,
          feature: "child_workflows",
          normalize_options: method(:symbolize_options)
        )
      end
      assert_match(
        /ActiveJob::ConfiguredJob internals changed for child_workflows.*@job_class.*ActiveJob::Temporal\.job/,
        error.message
      )
    end
  end

  describe ".job_class" do
    it "extracts the configured job class for compatibility helpers" do
      call_recorded_method(ActiveJob::Temporal::Logger, :warn)

      assert_same job_class, described_class.job_class(job_class.set(queue: "critical"), feature: "conditional_enqueue")
    end
  end

  def assert_private_api_warning(logger_warnings, feature:, replacement:)
    warning = logger_warnings.calls_for(:warn).find do |call|
      call.arguments == ["active_job_configured_job_private_api"] &&
        call.keywords[:feature] == feature &&
        call.keywords[:replacement] == replacement
    end

    refute_nil warning
  end
end
