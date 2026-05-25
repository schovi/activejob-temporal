# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe ActiveJob::Temporal::ConfiguredJobCompatibility do
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
      expect(
        described_class.payload(job_class, feature: "chain", normalize_options: method(:symbolize_options))
      ).to be_nil
    end

    it "extracts configured job class and options through the isolated compatibility layer" do
      allow(ActiveJob::Temporal::Logger).to receive(:warn)

      payload = described_class.payload(
        job_class.set(queue: "critical", priority: 7),
        feature: "chain",
        normalize_options: method(:symbolize_options)
      )

      expect(payload).to eq(
        job_class: "ConfiguredCompatibilityJob",
        options: {
          queue: "critical",
          priority: 7
        }
      )
      expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
        "active_job_configured_job_private_api",
        hash_including(feature: "chain", replacement: "ActiveJob::Temporal.job")
      )
    end

    it "fails clearly when ActiveJob moves configured job internals to an untested version" do
      allow(described_class).to receive(:active_job_version).and_return(Gem::Version.new("8.2.0"))

      expect do
        described_class.payload(
          job_class.set(queue: "critical"),
          feature: "chain",
          normalize_options: method(:symbolize_options)
        )
      end.to raise_error(
        ArgumentError,
        /ActiveJob::ConfiguredJob internals are not supported for chain on ActiveJob 8\.2\.0.*ActiveJob::Temporal\.job/
      )
    end

    it "fails clearly when configured job internals do not expose a job class" do
      configured_job = ActiveJob::ConfiguredJob.allocate

      expect do
        described_class.payload(
          configured_job,
          feature: "child_workflows",
          normalize_options: method(:symbolize_options)
        )
      end.to raise_error(
        ArgumentError,
        /ActiveJob::ConfiguredJob internals changed for child_workflows.*@job_class.*ActiveJob::Temporal\.job/
      )
    end
  end

  describe ".job_class" do
    it "extracts the configured job class for compatibility helpers" do
      allow(ActiveJob::Temporal::Logger).to receive(:warn)

      expect(
        described_class.job_class(job_class.set(queue: "critical"), feature: "conditional_enqueue")
      ).to eq(job_class)
    end
  end
end
