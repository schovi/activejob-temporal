# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::RateLimitOptions do
  describe ".normalize" do
    it "normalizes symbolic periods to seconds" do
      expect(described_class.normalize(100, per: :second)).to eq(limit: 100, interval: 1.0)
      expect(described_class.normalize(10, per: :minute)).to eq(limit: 10, interval: 60.0)
      expect(described_class.normalize(1, per: :hour)).to eq(limit: 1, interval: 3600.0)
    end

    it "accepts numeric and duration periods" do
      expect(described_class.normalize(25, per: 2.5)).to eq(limit: 25, interval: 2.5)
      expect(described_class.normalize(5, per: 2.minutes)).to eq(limit: 5, interval: 120.0)
    end

    it "preserves non-blank custom keys" do
      expect(described_class.normalize(5, per: :minute, key: "api")).to eq(
        limit: 5,
        interval: 60.0,
        key: "api"
      )
    end

    it "rejects invalid limits and periods" do
      expect { described_class.normalize(0, per: :second) }
        .to raise_error(ArgumentError, /positive integer/)
      expect { described_class.normalize(1, per: :week) }
        .to raise_error(ArgumentError, /unsupported rate limit period/)
      expect { described_class.normalize(1, per: 0) }
        .to raise_error(ArgumentError, /period must be finite and positive/)
      expect { described_class.normalize(1, per: Float::INFINITY) }
        .to raise_error(ArgumentError, /period must be finite and positive/)
      expect { described_class.normalize(1, per: Float::NAN) }
        .to raise_error(ArgumentError, /period must be finite and positive/)
    end
  end

  describe ".normalize_hash" do
    it "normalizes hash values from symbol or string keys" do
      expect(described_class.normalize_hash("limit" => 10, "per" => :minute)).to eq(
        limit: 10,
        interval: 60.0
      )
    end

    it "accepts already normalized interval values" do
      expect(described_class.normalize_hash(limit: 10, interval: 30.0)).to eq(
        limit: 10,
        interval: 30.0
      )
    end
  end

  describe ".rate_limit" do
    it "is included into ActiveJob classes" do
      expect(ActiveJob::Base.included_modules).to include(described_class)
    end

    it "stores per-job rate limit metadata" do
      job_class = Class.new(ActiveJob::Base) do
        rate_limit 100, per: :second
      end

      expect(job_class.rate_limit).to eq(limit: 100, interval: 1.0)
    end

    it "inherits rate limit metadata from parent job classes" do
      parent_class = Class.new(ActiveJob::Base) do
        rate_limit 100, per: :second
      end
      child_class = Class.new(parent_class)

      expect(child_class.rate_limit).to eq(limit: 100, interval: 1.0)
    end

    it "allows child job classes to override inherited rate limits" do
      parent_class = Class.new(ActiveJob::Base) do
        rate_limit 100, per: :second
      end
      child_class = Class.new(parent_class) do
        rate_limit 10, per: :minute
      end

      expect(child_class.rate_limit).to eq(limit: 10, interval: 60.0)
    end

    it "requires a period when configuring a limit" do
      job_class = Class.new(ActiveJob::Base)

      expect { job_class.rate_limit(100) }
        .to raise_error(ArgumentError, /period is required/)
    end
  end
end
