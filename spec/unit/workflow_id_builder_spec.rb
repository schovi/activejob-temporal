# frozen_string_literal: true

require "spec_helper"
require_relative "../fixtures/sample_jobs"

RSpec.describe ActiveJob::Temporal::WorkflowIdBuilder do
  subject(:builder) { described_class.new }

  describe "#build" do
    let(:job) do
      job = SimpleJob.new
      job.job_id = "abc-123"
      job
    end

    it "returns the default workflow ID format" do
      expect(builder.build(job)).to eq("ajwf:SimpleJob:abc-123")
    end

    it "is deterministic for the same job instance" do
      expect(builder.build(job)).to eq(builder.build(job))
    end

    it "includes the job class name" do
      scheduled_job = ScheduledJob.new
      scheduled_job.job_id = job.job_id

      expect(builder.build(scheduled_job)).to eq("ajwf:ScheduledJob:abc-123")
      expect(builder.build(scheduled_job)).not_to eq(builder.build(job))
    end

    it "includes the job ID" do
      other_job = SimpleJob.new
      other_job.job_id = "def-456"

      expect(builder.build(other_job)).to eq("ajwf:SimpleJob:def-456")
      expect(builder.build(other_job)).not_to eq(builder.build(job))
    end

    it "uses the injected strategy when provided" do
      custom_builder = described_class.new(->(job) { "custom:#{job.job_id}" })

      expect(custom_builder.build(job)).to eq("custom:abc-123")
    end

    it "allows tenant-style workflow IDs" do
      custom_builder = described_class.new(->(job) { "tenant-42:ajwf:#{job.class.name}:#{job.job_id}" })

      expect(custom_builder.build(job)).to eq("tenant-42:ajwf:SimpleJob:abc-123")
    end

    it "allows Temporal-compatible punctuation and Unicode workflow IDs" do
      custom_builder = described_class.new(
        ->(job) { "tenant/acme@example.com/ajwf:RésuméJob:#{job.job_id}" }
      )

      expect(custom_builder.build(job)).to eq("tenant/acme@example.com/ajwf:RésuméJob:abc-123")
    end

    it "rejects non-string strategy output" do
      custom_builder = described_class.new(->(_job) { 123 })

      expect { custom_builder.build(job) }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /must return a String/)
    end

    it "rejects generators that cannot accept the job argument" do
      custom_builder = described_class.new(-> { "custom-id" })

      expect { custom_builder.build(job) }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /must accept one positional ActiveJob argument/)
    end

    it "rejects blank workflow IDs" do
      custom_builder = described_class.new(->(_job) { "" })

      expect { custom_builder.build(job) }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /must not be blank/)
    end

    it "rejects workflow IDs with control characters" do
      custom_builder = described_class.new(->(_job) { "bad\nworkflow" })

      expect { custom_builder.build(job) }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /control characters/)
    end

    it "rejects workflow IDs that are not UTF-8 compatible" do
      custom_builder = described_class.new(->(_job) { "\xC3".b })

      expect { custom_builder.build(job) }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /valid UTF-8/)
    end

    it "rejects workflow IDs longer than 255 characters" do
      custom_builder = described_class.new(->(_job) { "a" * 256 })

      expect { custom_builder.build(job) }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /maximum length is 255/)
    end
  end

  describe "#build_from_job_class" do
    it "returns the same format without a job instance" do
      workflow_id = builder.build_from_job_class(SimpleJob, "550e8400-e29b-41d4-a716-446655440000")

      expect(workflow_id).to eq("ajwf:SimpleJob:550e8400-e29b-41d4-a716-446655440000")
    end
  end
end
