# frozen_string_literal: true

require "spec_helper"

describe ActiveJob::Temporal::JobIdValidation do
  describe ".validate!" do
    it "accepts UUID job IDs" do
      assert_nothing_raised { described_class.validate!("550e8400-e29b-41d4-a716-446655440000") }
    end

    it "accepts custom job IDs that need visibility query escaping" do
      assert_nothing_raised { described_class.validate!("tenant'42:invoice-123") }
    end

    it "accepts schedule-style execution job IDs" do
      schedule_job_id = "ajschwf:daily-report-2026-05-25T20:07:45Z:019e60c0-2587-710d-8633-a0f90e9dd6f9"

      assert_nothing_raised { described_class.validate!(schedule_job_id) }
    end

    it "rejects blank job IDs" do
      error = assert_raises(ArgumentError) { described_class.validate!(" \t") }

      assert_match(/must not be blank/, error.message)
    end

    it "rejects non-string job IDs" do
      error = assert_raises(ArgumentError) { described_class.validate!(123) }

      assert_match(/must be a String/, error.message)
    end

    it "rejects control characters" do
      error = assert_raises(ArgumentError) { described_class.validate!("job\n123") }

      assert_match(/control characters/, error.message)
    end

    it "rejects unbounded job IDs" do
      job_id = "a" * (described_class::MAX_JOB_ID_LENGTH + 1)

      error = assert_raises(ArgumentError) { described_class.validate!(job_id) }

      assert_match(/maximum length/, error.message)
    end
  end

  describe ".schedule_execution_reference" do
    it "returns workflow and run IDs for schedule execution job IDs" do
      job_id = "ajschwf:daily-report-2026-05-25T20:07:45Z:019e60c0-2587-710d-8633-a0f90e9dd6f9"

      assert_equal(
        {
          workflow_id: "ajschwf:daily-report-2026-05-25T20:07:45Z",
          run_id: "019e60c0-2587-710d-8633-a0f90e9dd6f9"
        },
        described_class.schedule_execution_reference(job_id)
      )
    end

    it "returns nil for non-schedule job IDs" do
      assert_nil described_class.schedule_execution_reference("invoice-123")
    end
  end
end
