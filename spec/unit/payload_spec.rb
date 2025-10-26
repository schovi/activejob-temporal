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

    it "raises when serialized payload exceeds configured size limit" do
      large_argument = "x" * 2048
      big_job = SimpleJob.new([large_argument])

      ActiveJob::Temporal.configure do |config|
        config.max_payload_size_kb = 1
      end

      expect { described_class.from_job(big_job) }
        .to raise_error(ActiveJob::SerializationError, /exceeds limit/)
    end

    it "raises when arguments contain non-serializable objects" do
      bad_job = SimpleJob.new([proc {}])

      expect { described_class.from_job(bad_job) }
        .to raise_error(ActiveJob::SerializationError)
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
