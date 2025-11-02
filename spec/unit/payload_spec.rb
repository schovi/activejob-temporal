# frozen_string_literal: true

require "spec_helper"
require "globalid"
require_relative "../fixtures/sample_jobs"

class FakeGlobalModel
  include GlobalID::Identification

  attr_reader :id

  def initialize(id)
    @id = id
  end
end

RSpec.describe ActiveJob::Temporal::Payload do
  before do
    ActiveJob::Temporal.configure do |config|
      config.max_payload_size_kb = 250
    end
  end

  describe ".from_job" do
    let(:job) { SimpleJob.new(["alpha", 123, { nested: true }]) }

    it "serializes ActiveJob attributes into a payload hash" do
      payload = described_class.from_job(job)

      expect(payload).to include(
        job_class: job.class.name,
        job_id: job.job_id,
        queue_name: job.queue_name,
        executions: job.executions,
        exception_executions: job.exception_executions
      )
      expect(payload[:arguments]).to eq(ActiveJob::Arguments.serialize(job.arguments))
    end

    it "includes scheduled_at in ISO8601 when provided" do
      scheduled_time = Time.utc(2024, 10, 20, 12, 0, 0)

      payload = described_class.from_job(job, scheduled_at: scheduled_time)

      expect(payload[:scheduled_at]).to eq(scheduled_time.iso8601)
    end

    it "accepts preformatted ISO8601 scheduled_at strings" do
      iso_string = "2024-10-20T12:00:00Z"
      payload = described_class.from_job(job, scheduled_at: iso_string)

      expect(payload[:scheduled_at]).to eq(iso_string)
    end

    it "coerces scheduled_at values that respond to to_time" do
      base_time = Time.utc(2024, 11, 10, 9, 30, 0)
      to_time_only = Class.new do
        def initialize(time)
          @time = time
        end

        def to_time
          @time
        end
      end

      payload = described_class.from_job(job, scheduled_at: to_time_only.new(base_time))

      expect(payload[:scheduled_at]).to eq(base_time.iso8601)
    end

    it "raises when scheduled_at string is not ISO8601" do
      invalid_timestamp = "20/10/2024 12:00"

      expect { described_class.from_job(job, scheduled_at: invalid_timestamp) }
        .to raise_error(ArgumentError, /convertible to Time/)
    end

    it "accepts payload under size limit" do
      small_job = SimpleJob.new(%w[small data])

      ActiveJob::Temporal.configure do |config|
        config.max_payload_size_kb = 250
      end

      expect { described_class.from_job(small_job) }.not_to raise_error
    end

    it "accepts payload at exactly the size limit" do
      # Create a payload that's approximately 250 KB when serialized
      # Account for JSON overhead (job_class, job_id, etc.)
      large_argument = "x" * ((250 * 1024) - 500) # Leave room for metadata
      big_job = SimpleJob.new([large_argument])

      ActiveJob::Temporal.configure do |config|
        config.max_payload_size_kb = 250
      end

      # This should not raise since we're at or just under the limit
      expect { described_class.from_job(big_job) }.not_to raise_error
    end

    it "raises when serialized payload exceeds configured size limit" do
      large_argument = "x" * 2048
      big_job = SimpleJob.new([large_argument])

      ActiveJob::Temporal.configure do |config|
        config.max_payload_size_kb = 1
      end

      expect { described_class.from_job(big_job) }
        .to raise_error(ActiveJob::SerializationError, /exceeds maximum allowed size/)
    end

    it "raises with descriptive error message including KB sizes and guidance" do
      large_argument = "x" * 2048
      big_job = SimpleJob.new([large_argument])

      ActiveJob::Temporal.configure do |config|
        config.max_payload_size_kb = 1
      end

      expect { described_class.from_job(big_job) }
        .to raise_error(ActiveJob::SerializationError) do |error|
          expect(error.message).to match(/Job payload size \(\d+\.\d+ KB\) exceeds maximum allowed size \(1 KB\)/)
          expect(error.message).to include("Consider reducing argument size or using references (e.g., database IDs)")
        end
    end

    it "raises when arguments contain non-serializable objects" do
      bad_job = SimpleJob.new([proc {}])

      expect { described_class.from_job(bad_job) }
        .to raise_error(ActiveJob::SerializationError)
    end

    context "boundary conditions for payload size" do
      it "accepts payload that is 1 byte under the limit" do
        # Create a payload that's just under 50KB limit
        # Estimate: SimpleJob class name + job_id + args = ~100 bytes baseline
        # So create an argument that brings total to exactly 50KB - 1 byte
        target_size_kb = 50
        estimate_overhead = 200 # rough estimate for metadata
        arg_size = (target_size_kb * 1024) - estimate_overhead - 1
        job_with_arg = SimpleJob.new(["x" * arg_size])

        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = target_size_kb
        end

        # Should not raise when under limit
        expect { described_class.from_job(job_with_arg) }.not_to raise_error
      end

      it "accepts payload at exact size boundary" do
        # Create a payload at exactly the limit by adjusting argument size
        target_size_kb = 25
        estimate_overhead = 200
        arg_size = (target_size_kb * 1024) - estimate_overhead
        job_at_limit = SimpleJob.new(["y" * arg_size])

        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = target_size_kb
        end

        # Should not raise when exactly at limit
        expect { described_class.from_job(job_at_limit) }.not_to raise_error
      end

      it "rejects payload that is over the limit" do
        # Create a very small limit and a payload clearly over it
        target_size_kb = 2
        large_arg_size = (target_size_kb * 1024) + 100 # Clearly over limit

        job_over = SimpleJob.new(["z" * large_arg_size])
        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = target_size_kb
        end

        expect { described_class.from_job(job_over) }
          .to raise_error(ActiveJob::SerializationError, /exceeds maximum allowed size/)
      end

      it "accepts empty payload (0 bytes argument)" do
        job_empty = SimpleJob.new([])

        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = 1
        end

        # Empty job should always pass
        expect { described_class.from_job(job_empty) }.not_to raise_error
      end

      it "accepts job with nil arguments" do
        # Job with no arguments (shouldn't raise even with small limit)
        job_nil = Class.new(ActiveJob::Base) { }
        job_instance = job_nil.new
        job_instance.arguments = nil

        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = 1
        end

        expect { described_class.from_job(job_instance) }.not_to raise_error
      end
    end
  end

  describe ".deserialize_args" do
    it "round-trips job arguments" do
      job = SimpleJob.new(["string", 123, { foo: "bar" }])
      payload = described_class.from_job(job)

      expect(described_class.deserialize_args(payload)).to eq(job.arguments)
    end

    it "raises when payload is missing arguments" do
      expect { described_class.deserialize_args({}) }
        .to raise_error(ActiveJob::SerializationError)
    end

    it "round-trips GlobalID compatible objects" do
      GlobalID.app = "aj-temporal-test"

      model = FakeGlobalModel.new(99)
      job = SimpleJob.new([model])
      global_id = model.to_global_id.to_s

      allow(GlobalID::Locator).to receive(:locate).with(global_id).and_return(model)

      payload = described_class.from_job(job)
      expect(payload[:arguments].first["_aj_globalid"]).to eq(global_id)

      expect(described_class.deserialize_args(payload)).to eq([model])
    end
  end
end
