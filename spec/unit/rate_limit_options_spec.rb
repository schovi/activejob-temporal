# frozen_string_literal: true

require "spec_helper"

describe ActiveJob::Temporal::RateLimitOptions do
  describe ".normalize" do
    it "normalizes symbolic periods to seconds" do
      assert_equal({ limit: 100, interval: 1.0 }, described_class.normalize(100, per: :second))
      assert_equal({ limit: 10, interval: 60.0 }, described_class.normalize(10, per: :minute))
      assert_equal({ limit: 1, interval: 3600.0 }, described_class.normalize(1, per: :hour))
    end

    it "accepts numeric and duration periods" do
      assert_equal({ limit: 25, interval: 2.5 }, described_class.normalize(25, per: 2.5))
      assert_equal({ limit: 5, interval: 120.0 }, described_class.normalize(5, per: 2.minutes))
    end

    it "preserves non-blank custom keys" do
      expected_options = {
        limit: 5,
        interval: 60.0,
        key: "api"
      }

      assert_equal expected_options, described_class.normalize(5, per: :minute, key: "api")
    end

    it "rejects invalid limits and periods" do
      error = assert_raises(ArgumentError) { described_class.normalize(0, per: :second) }
      assert_match(/positive integer/, error.message)

      error = assert_raises(ArgumentError) { described_class.normalize(1, per: :week) }
      assert_match(/unsupported rate limit period/, error.message)

      error = assert_raises(ArgumentError) { described_class.normalize(1, per: 0) }
      assert_match(/period must be finite and positive/, error.message)

      error = assert_raises(ArgumentError) { described_class.normalize(1, per: Float::INFINITY) }
      assert_match(/period must be finite and positive/, error.message)

      error = assert_raises(ArgumentError) { described_class.normalize(1, per: Float::NAN) }
      assert_match(/period must be finite and positive/, error.message)
    end
  end

  describe ".normalize_hash" do
    it "normalizes hash values from symbol or string keys" do
      expected_options = {
        limit: 10,
        interval: 60.0
      }

      assert_equal expected_options, described_class.normalize_hash("limit" => 10, "per" => :minute)
    end

    it "accepts already normalized interval values" do
      expected_options = {
        limit: 10,
        interval: 30.0
      }

      assert_equal expected_options, described_class.normalize_hash(limit: 10, interval: 30.0)
    end
  end

  describe ".rate_limit" do
    it "is included into ActiveJob classes" do
      assert_includes ActiveJob::Base.included_modules, described_class
    end

    it "stores per-job rate limit metadata" do
      job_class = Class.new(ActiveJob::Base) do
        rate_limit 100, per: :second
      end

      assert_equal({ limit: 100, interval: 1.0 }, job_class.rate_limit)
    end

    it "inherits rate limit metadata from parent job classes" do
      parent_class = Class.new(ActiveJob::Base) do
        rate_limit 100, per: :second
      end
      child_class = Class.new(parent_class)

      assert_equal({ limit: 100, interval: 1.0 }, child_class.rate_limit)
    end

    it "allows child job classes to override inherited rate limits" do
      parent_class = Class.new(ActiveJob::Base) do
        rate_limit 100, per: :second
      end
      child_class = Class.new(parent_class) do
        rate_limit 10, per: :minute
      end

      assert_equal({ limit: 10, interval: 60.0 }, child_class.rate_limit)
    end

    it "requires a period when configuring a limit" do
      job_class = Class.new(ActiveJob::Base)

      error = assert_raises(ArgumentError) { job_class.rate_limit(100) }
      assert_match(/period is required/, error.message)
    end
  end
end
