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
      global_config.rate_limiter = nil
      global_config.global_rate_limit = nil
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

  it "includes per-job rate limits with a job-specific key" do
    config.rate_limiter = ->(_rate_limits) { 0 }
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "RateLimitedJob"

      rate_limit 100, per: :second
    end
    job = job_class.new

    payload = described_class.new(config).build(job)

    expect(payload[:rate_limits]).to eq([
                                          {
                                            limit: 100,
                                            interval: 1.0,
                                            key: "activejob-temporal:job:RateLimitedJob"
                                          }
                                        ])
  end

  it "requires a limiter backend when per-job rate limits are configured" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "MissingLimiterRateLimitedJob"

      rate_limit 100, per: :second
    end

    expect { described_class.new(config).build(job_class.new) }
      .to raise_error(ActiveJob::Temporal::ConfigurationError, /rate_limiter is required/)
  end

  it "includes global and per-job rate limits" do
    config.rate_limiter = ->(_rate_limits) { 0 }
    config.global_rate_limit = { limit: 1000, per: :minute }
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "GlobalAndJobRateLimitedJob"

      rate_limit 100, per: :second, key: "external-api"
    end

    payload = described_class.new(config).build(job_class.new)

    expect(payload[:rate_limits]).to eq([
                                          {
                                            limit: 1000,
                                            interval: 60.0,
                                            key: "activejob-temporal:global"
                                          },
                                          {
                                            limit: 100,
                                            interval: 1.0,
                                            key: "external-api"
                                          }
                                        ])
  end

  it "adds dead letter metadata when a dead letter queue is configured" do
    config.dead_letter_queue = "failed_jobs"
    config.dead_letter_after_attempts = 3
    job = build_job("DeadLetterBuilderJob")

    payload = described_class.new(config).build(job)

    expect(payload[:dead_letter]).to eq(
      queue: "failed_jobs",
      after_attempts: 3,
      job_class: "DeadLetterBuilderJob",
      job_id: job.job_id,
      queue_name: "default"
    )
  end

  it "omits dead letter metadata when dead letter routing is disabled" do
    job = build_job("NoDeadLetterBuilderJob")

    payload = described_class.new(config).build(job)

    expect(payload).not_to have_key(:dead_letter)
  end

  it "uses dead_letter_after_attempts as the activity retry limit" do
    config.dead_letter_queue = "failed_jobs"
    config.dead_letter_after_attempts = 2
    allow(ActiveJob::Temporal::RetryMapper).to receive(:for).and_return(
      initial_interval: 30.0,
      backoff_coefficient: 2.0,
      maximum_attempts: 5,
      non_retryable_error_types: []
    )

    payload = described_class.new(config).build(build_job("DeadLetterAttemptsBuilderJob"))

    expect(payload[:retry_policy][:maximum_attempts]).to eq(2)
  end

  it "records the retry policy attempt limit when no dead letter threshold is configured" do
    config.dead_letter_queue = "failed_jobs"
    allow(ActiveJob::Temporal::RetryMapper).to receive(:for).and_return(
      initial_interval: 30.0,
      backoff_coefficient: 2.0,
      maximum_attempts: 4,
      non_retryable_error_types: []
    )

    payload = described_class.new(config).build(build_job("DeadLetterPolicyLimitBuilderJob"))

    expect(payload[:dead_letter][:after_attempts]).to eq(4)
  end

  it "keeps workflow-control fields readable when payload encryption is enabled" do
    job = build_job("EncryptedBuilderJob")

    config.encryption_key = encryption_key
    config.encryption_old_keys = []
    config.encrypt_payload = true
    config.dead_letter_queue = "failed_jobs"
    config.dead_letter_after_attempts = 3
    config.rate_limiter = ->(_rate_limits) { 0 }
    config.global_rate_limit = { limit: 1000, per: :minute }

    payload = described_class.new(config).build(job)

    expect(payload).to include(
      encrypted_payload: true,
      encrypted_payload_version: 1,
      encrypted_data: a_kind_of(String),
      default_activity_options: hash_including(start_to_close_timeout: 900.0),
      retry_policy: hash_including(maximum_attempts: 3),
      rate_limits: [hash_including(limit: 1000, interval: 60.0, key: "activejob-temporal:global")],
      dead_letter: hash_including(
        queue: "failed_jobs",
        after_attempts: 3,
        job_class: "EncryptedBuilderJob",
        job_id: job.job_id
      )
    )
    expect(payload).not_to have_key(:job_class)
    expect(ActiveJob::Temporal::Payload.deserialize_payload(payload, config: config)).to include(
      job_class: "EncryptedBuilderJob",
      default_activity_options: hash_including(start_to_close_timeout: 900.0),
      retry_policy: hash_including(maximum_attempts: 3),
      rate_limits: [hash_including(limit: 1000, interval: 60.0, key: "activejob-temporal:global")],
      dead_letter: hash_including(queue: "failed_jobs")
    )
  end

  it "keeps workflow-control fields outside non-JSON serializer envelopes" do
    config.payload_serializer = :message_pack
    config.dead_letter_queue = "failed_jobs"
    config.dead_letter_after_attempts = 3
    config.rate_limiter = ->(_rate_limits) { 0 }
    config.global_rate_limit = { limit: 1000, per: :minute }
    job = build_job("SerializedBuilderJob")

    payload = described_class.new(config).build(job)

    expect(payload).to include(
      serialized_payload: true,
      payload_serializer: "message_pack",
      payload_serializer_version: 1,
      serialized_data: a_kind_of(String),
      default_activity_options: hash_including(start_to_close_timeout: 900.0),
      retry_policy: hash_including(maximum_attempts: 3),
      rate_limits: [hash_including(limit: 1000, interval: 60.0, key: "activejob-temporal:global")],
      dead_letter: hash_including(
        queue: "failed_jobs",
        after_attempts: 3,
        job_class: "SerializedBuilderJob",
        job_id: job.job_id
      )
    )
    expect(payload).not_to have_key(:job_class)
    expect(payload).not_to have_key(:arguments)

    config.payload_serializer = :json
    expect(ActiveJob::Temporal::Payload.deserialize_payload(payload, config: config)).to include(
      job_class: "SerializedBuilderJob",
      default_activity_options: hash_including(start_to_close_timeout: 900.0),
      retry_policy: hash_including(maximum_attempts: 3),
      rate_limits: [hash_including(limit: 1000, interval: 60.0, key: "activejob-temporal:global")],
      dead_letter: hash_including(queue: "failed_jobs")
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
