# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::JobIdValidation do
  describe ".validate!" do
    it "accepts UUID job IDs" do
      expect { described_class.validate!("550e8400-e29b-41d4-a716-446655440000") }.not_to raise_error
    end

    it "accepts custom job IDs that need visibility query escaping" do
      expect { described_class.validate!("tenant'42:invoice-123") }.not_to raise_error
    end

    it "accepts schedule-style execution job IDs" do
      schedule_job_id = "ajschwf:daily-report-2026-05-25T20:07:45Z:019e60c0-2587-710d-8633-a0f90e9dd6f9"

      expect { described_class.validate!(schedule_job_id) }.not_to raise_error
    end

    it "rejects blank job IDs" do
      expect { described_class.validate!(" \t") }.to raise_error(ArgumentError, /must not be blank/)
    end

    it "rejects non-string job IDs" do
      expect { described_class.validate!(123) }.to raise_error(ArgumentError, /must be a String/)
    end

    it "rejects control characters" do
      expect { described_class.validate!("job\n123") }.to raise_error(ArgumentError, /control characters/)
    end

    it "rejects unbounded job IDs" do
      job_id = "a" * (described_class::MAX_JOB_ID_LENGTH + 1)

      expect { described_class.validate!(job_id) }.to raise_error(ArgumentError, /maximum length/)
    end
  end

  describe ".schedule_execution_reference" do
    it "returns workflow and run IDs for schedule execution job IDs" do
      job_id = "ajschwf:daily-report-2026-05-25T20:07:45Z:019e60c0-2587-710d-8633-a0f90e9dd6f9"

      expect(described_class.schedule_execution_reference(job_id)).to eq(
        workflow_id: "ajschwf:daily-report-2026-05-25T20:07:45Z",
        run_id: "019e60c0-2587-710d-8633-a0f90e9dd6f9"
      )
    end

    it "returns nil for non-schedule job IDs" do
      expect(described_class.schedule_execution_reference("invoice-123")).to be_nil
    end
  end
end
