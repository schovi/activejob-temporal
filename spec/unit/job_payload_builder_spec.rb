# frozen_string_literal: true

require "spec_helper"
require "active_job"
require "base64"

RSpec.describe ActiveJob::Temporal::JobPayloadBuilder do
  let(:config) { ActiveJob::Temporal::Configuration.new }

  before do
    ActiveJob::Temporal.configure do |global_config|
      global_config.max_payload_size_kb = 250
      global_config.encrypt_payload = false
      global_config.encryption_key = nil
      global_config.encryption_old_keys = []
    end

    allow(ActiveJob::Temporal::Logger).to receive(:info)
    allow(ActiveJob::Temporal::Logger).to receive(:warn)
    allow(ActiveJob::Temporal::Logger).to receive(:error)
  end

  it "builds a workflow payload with global activity defaults" do
    config.default_heartbeat_timeout = 45.seconds
    config.default_schedule_to_start_timeout = 2.minutes
    config.default_schedule_to_close_timeout = 20.minutes
    job = build_job("PayloadBuilderJob")

    payload = described_class.new(config).build(job)

    expect(payload[:default_activity_options]).to eq(
      start_to_close_timeout: 900.0,
      schedule_to_close_timeout: 1200.0,
      schedule_to_start_timeout: 120.0,
      heartbeat_timeout: 45.0
    )
  end

  it "includes per-job temporal options" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "ScheduledTimeoutJob"

      temporal_options start_to_close_timeout: 2.hours
    end
    job = job_class.new

    payload = described_class.new(config).build(job)

    expect(payload[:temporal_options]).to eq(start_to_close_timeout: 7200.0)
  end

  it "keeps workflow-control fields readable when payload encryption is enabled" do
    job = build_job("EncryptedBuilderJob")

    config.encryption_key = encryption_key
    config.encryption_old_keys = []
    config.encrypt_payload = true

    payload = described_class.new(config).build(job)

    expect(payload).to include(
      encrypted_payload: true,
      encrypted_payload_version: 1,
      encrypted_data: a_kind_of(String),
      default_activity_options: hash_including(start_to_close_timeout: 900.0),
      retry_policy: a_kind_of(Hash)
    )
    expect(payload).not_to have_key(:job_class)
    expect(ActiveJob::Temporal::Payload.deserialize_payload(payload, config: config)).to include(
      job_class: "EncryptedBuilderJob",
      default_activity_options: hash_including(start_to_close_timeout: 900.0),
      retry_policy: a_kind_of(Hash)
    )
  end

  it "enforces payload size after workflow-control fields are added" do
    job = build_job("FinalSizeBuilderJob")
    allow(ActiveJob::Temporal::RetryMapper).to receive(:for).and_return(
      non_retryable_error_types: ["x" * 2048]
    )

    config.max_payload_size_kb = 1

    expect { described_class.new(config).build(job) }
      .to raise_error(ActiveJob::SerializationError, /exceeds maximum allowed size/)
  end

  private

  def build_job(name)
    Class.new(ActiveJob::Base) do
      define_singleton_method(:name) { name }
    end.new
  end

  def encryption_key
    Base64.strict_encode64("builder-key".ljust(32, "-")[0, 32])
  end
end
