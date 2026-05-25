# frozen_string_literal: true

require "spec_helper"
require "base64"
require "globalid"
require_relative "../fixtures/sample_jobs"

class FakeGlobalModel
  include GlobalID::Identification

  attr_reader :id

  def initialize(id)
    @id = id
  end
end

class MemoryPayloadStorageAdapter
  attr_reader :references

  def initialize
    @references = []
    @payloads = {}
    @metadata = {}
  end

  def dump(payload, metadata:)
    reference = "payload-#{@references.length + 1}"
    @references << reference
    @payloads[reference] = payload
    @metadata[reference] = metadata
    reference
  end

  def load(reference)
    @payloads.fetch(reference)
  end

  def payload_for(reference)
    @payloads.fetch(reference)
  end

  def metadata_for(reference)
    @metadata.fetch(reference)
  end
end

RSpec.describe ActiveJob::Temporal::Payload do
  before do
    ActiveJob::Temporal.configure do |config|
      config.max_payload_size_kb = 250
      config.encrypt_payload = false
      config.encryption_key = nil
      config.encryption_old_keys = []
      config.payload_serializer = :json
      config.payload_storage_adapter = nil
      config.payload_storage_threshold_kb = nil
    end

    allow(ActiveJob::Temporal::Logger).to receive(:info)
    allow(ActiveJob::Temporal::Logger).to receive(:warn)
    allow(ActiveJob::Temporal::Logger).to receive(:error)
    allow(ActiveJob::Temporal::Observability).to receive(:emit)
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

    it "stores full ActiveJob serialized data when the job supports it" do
      job_class = stub_const("FullSerializedPayloadJob", Class.new(ActiveJob::Base) do
        attr_accessor :tenant

        def serialize
          super.merge("tenant" => tenant)
        end
      end)
      job = job_class.new("payload")
      job.provider_job_id = "provider-job-id"
      job.priority = 7
      job.locale = "en"
      job.timezone = "UTC"
      job.tenant = "tenant-42"

      payload = described_class.from_job(job)

      expect(payload[:active_job]).to include(
        "job_class" => "FullSerializedPayloadJob",
        "job_id" => job.job_id,
        "provider_job_id" => "provider-job-id",
        "queue_name" => "default",
        "priority" => 7,
        "locale" => "en",
        "timezone" => "UTC",
        "tenant" => "tenant-42"
      )
    end

    it "uses active_job as the canonical argument representation for ActiveJob payloads" do
      job_class = Class.new(ActiveJob::Base) do
        def self.name = "CanonicalArgumentsPayloadJob"
      end
      active_job = job_class.new("payload")

      payload = described_class.from_job(active_job)

      expect(payload).not_to have_key(:arguments)
      expect(payload[:active_job]["arguments"]).to eq(ActiveJob::Arguments.serialize(active_job.arguments))
      expect(described_class.deserialize_args(payload)).to eq(active_job.arguments)
    end

    it "does not duplicate large serialized arguments in new payloads" do
      job_class = Class.new(ActiveJob::Base) do
        def self.name = "LargeArgumentsPayloadJob"
      end
      large_job = job_class.new("x" * 50_000)
      serialized_arguments = ActiveJob::Arguments.serialize(large_job.arguments)

      payload = described_class.from_job(large_job)
      legacy_payload = payload.merge(arguments: serialized_arguments)

      expect(payload).not_to have_key(:arguments)
      expect(JSON.generate(payload).bytesize).to be < (JSON.generate(legacy_payload).bytesize * 0.65)
    end

    it "emits serialized payload size observability" do
      payload = described_class.from_job(job)

      expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
        :payload_serialize,
        hash_including(
          job_class: payload[:job_class],
          job_id: payload[:job_id],
          queue: payload[:queue_name],
          bytes: kind_of(Integer)
        )
      )
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

    it "coerces scheduled_at strings accepted by ActiveSupport" do
      scheduled_time = "October 20, 2024 12:00 UTC"

      payload = described_class.from_job(job, scheduled_at: scheduled_time)

      expect(payload[:scheduled_at]).to eq("2024-10-20T12:00:00+00:00")
    end

    it "raises when scheduled_at string cannot be parsed" do
      invalid_timestamp = "not-a-date"

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

    context "with non-JSON payload serializers" do
      it "wraps MessagePack execution data and round-trips arguments" do
        ActiveJob::Temporal.config.payload_serializer = :message_pack

        payload = described_class.from_job(job)

        expect(payload).to include(
          serialized_payload: true,
          payload_serializer: "message_pack",
          payload_serializer_version: 1,
          serialized_data: a_kind_of(String)
        )
        expect(payload).not_to have_key(:job_class)
        expect(payload).not_to have_key(:arguments)
        expect(described_class.deserialize_payload(payload)).to include(
          job_class: job.class.name,
          job_id: job.job_id,
          queue_name: job.queue_name
        )
        expect(described_class.deserialize_args(payload)).to eq(job.arguments)
      end

      it "wraps Marshal execution data and round-trips arguments" do
        ActiveJob::Temporal.config.payload_serializer = :marshal

        payload = described_class.from_job(job)

        expect(payload).to include(
          serialized_payload: true,
          payload_serializer: "marshal",
          payload_serializer_version: 1,
          serialized_data: a_kind_of(String)
        )
        expect(payload).not_to have_key(:job_class)
        expect(payload).not_to have_key(:arguments)
        expect(described_class.deserialize_args(payload)).to eq(job.arguments)
      end

      it "preserves chain metadata outside serialized execution data" do
        ActiveJob::Temporal.config.payload_serializer = :message_pack
        chain = [
          {
            job_class: "SerializedChainNextJob",
            options: {
              queue: "reporting",
              priority: 7
            }
          }
        ]

        payload = described_class.from_job(job).merge(chain: chain)

        expect(payload).to include(
          serialized_payload: true,
          payload_serializer: "message_pack",
          payload_serializer_version: 1,
          serialized_data: a_kind_of(String),
          chain: chain
        )
        expect(described_class.deserialize_payload(payload)).to include(chain: chain)
      end

      it "reads legacy JSON payloads after the configured serializer changes" do
        ActiveJob::Temporal.config.payload_serializer = :json
        payload = described_class.from_job(job)
        ActiveJob::Temporal.config.payload_serializer = :message_pack

        expect(described_class.deserialize_args(payload)).to eq(job.arguments)
      end

      it "reads MessagePack payloads after the configured serializer changes" do
        ActiveJob::Temporal.config.payload_serializer = :message_pack
        payload = described_class.from_job(job)
        ActiveJob::Temporal.config.payload_serializer = :json

        expect(described_class.deserialize_args(payload)).to eq(job.arguments)
      end

      it "reads Marshal payloads after the configured serializer changes" do
        ActiveJob::Temporal.config.payload_serializer = :marshal
        payload = described_class.from_job(job)
        ActiveJob::Temporal.config.payload_serializer = :json

        expect(described_class.deserialize_args(payload)).to eq(job.arguments)
      end
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
        job_nil = Class.new(ActiveJob::Base)
        job_instance = job_nil.new
        job_instance.arguments = nil

        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = 1
        end

        expect { described_class.from_job(job_instance) }.not_to raise_error
      end
    end

    context "payload size monitoring" do
      it "does not log when payload size is below warning thresholds" do
        monitored_job = job_for_payload_usage(0.75, max_size_kb: 2)

        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = 2
        end

        described_class.from_job(monitored_job)

        expect(ActiveJob::Temporal::Logger).not_to have_received(:info)
        expect(ActiveJob::Temporal::Logger).not_to have_received(:warn)
        expect(ActiveJob::Temporal::Logger).not_to have_received(:error)
      end

      it "logs info when payload size reaches 80 percent of the limit" do
        monitored_job = job_for_payload_usage(0.85, max_size_kb: 2)

        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = 2
        end

        described_class.from_job(monitored_job)

        expect(ActiveJob::Temporal::Logger).to have_received(:info).with(
          "payload_size_large",
          hash_including(
            job_class: monitored_job.class.name,
            limit_kb: 2,
            size_kb: be_between(1.6, 1.8),
            percentage: be_between(80.0, 90.0)
          )
        )
        expect(ActiveJob::Temporal::Logger).not_to have_received(:warn)
        expect(ActiveJob::Temporal::Logger).not_to have_received(:error)
      end

      it "logs warn when payload size reaches 90 percent of the limit" do
        monitored_job = job_for_payload_usage(0.95, max_size_kb: 2)

        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = 2
        end

        described_class.from_job(monitored_job)

        expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
          "payload_size_near_limit",
          hash_including(
            job_class: monitored_job.class.name,
            limit_kb: 2,
            size_kb: be_between(1.8, 2.0),
            percentage: be_between(90.0, 100.0)
          )
        )
        expect(ActiveJob::Temporal::Logger).not_to have_received(:info)
        expect(ActiveJob::Temporal::Logger).not_to have_received(:error)
      end

      it "logs error with payload context when payload size exceeds the limit" do
        monitored_job = job_for_payload_usage(1.10, max_size_kb: 2)

        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = 2
        end

        expect { described_class.from_job(monitored_job) }
          .to raise_error(ActiveJob::SerializationError, /exceeds maximum allowed size/)

        expect(ActiveJob::Temporal::Logger).to have_received(:error).with(
          "payload_size_exceeded",
          hash_including(
            job_class: monitored_job.class.name,
            limit_kb: 2,
            size_kb: be > 2.0,
            percentage: be > 100.0
          )
        )
        expect(ActiveJob::Temporal::Logger).not_to have_received(:info)
        expect(ActiveJob::Temporal::Logger).not_to have_received(:warn)
      end

      it "logs info at exactly 80 percent of the limit" do
        monitored_job = job_for_payload_size((2 * 1024 * 0.8).ceil)

        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = 2
        end

        described_class.from_job(monitored_job)

        expect(ActiveJob::Temporal::Logger).to have_received(:info).with(
          "payload_size_large",
          hash_including(
            job_class: monitored_job.class.name,
            limit_kb: 2,
            percentage: 80.0
          )
        )
        expect(ActiveJob::Temporal::Logger).not_to have_received(:warn)
        expect(ActiveJob::Temporal::Logger).not_to have_received(:error)
      end

      it "logs warn at exactly 90 percent of the limit" do
        monitored_job = job_for_payload_size((2 * 1024 * 0.9).ceil)

        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = 2
        end

        described_class.from_job(monitored_job)

        expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
          "payload_size_near_limit",
          hash_including(
            job_class: monitored_job.class.name,
            limit_kb: 2,
            percentage: 90.0
          )
        )
        expect(ActiveJob::Temporal::Logger).not_to have_received(:info)
        expect(ActiveJob::Temporal::Logger).not_to have_received(:error)
      end

      it "logs warn and accepts payload at the exact size limit" do
        monitored_job = job_for_payload_size(2 * 1024)

        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = 2
        end

        expect { described_class.from_job(monitored_job) }.not_to raise_error

        expect(ActiveJob::Temporal::Logger).to have_received(:warn).with(
          "payload_size_near_limit",
          hash_including(
            job_class: monitored_job.class.name,
            limit_kb: 2,
            percentage: 100.0
          )
        )
        expect(ActiveJob::Temporal::Logger).not_to have_received(:info)
        expect(ActiveJob::Temporal::Logger).not_to have_received(:error)
      end

      it "logs error when payload is one byte over the limit" do
        monitored_job = job_for_payload_size((2 * 1024) + 1)

        ActiveJob::Temporal.configure do |config|
          config.max_payload_size_kb = 2
        end

        expect { described_class.from_job(monitored_job) }
          .to raise_error(ActiveJob::SerializationError, /exceeds maximum allowed size/)

        expect(ActiveJob::Temporal::Logger).to have_received(:error).with(
          "payload_size_exceeded",
          hash_including(
            job_class: monitored_job.class.name,
            limit_kb: 2,
            percentage: 100.0
          )
        )
        expect(ActiveJob::Temporal::Logger).not_to have_received(:info)
        expect(ActiveJob::Temporal::Logger).not_to have_received(:warn)
      end
    end

    context "with payload encryption enabled" do
      let(:job) { SimpleJob.new(["alpha", 123, { nested: true }]) }

      before do
        configure_payload_encryption
      end

      it "returns an encrypted envelope without plaintext job execution fields" do
        payload = described_class.from_job(job)

        expect(payload).to include(
          encrypted_payload: true,
          encrypted_payload_version: 1,
          encrypted_data: a_kind_of(String)
        )
        expect(payload).not_to have_key(:job_class)
        expect(payload).not_to have_key(:job_id)
        expect(payload).not_to have_key(:queue_name)
        expect(payload).not_to have_key(:arguments)
        expect(payload[:encrypted_data]).not_to include("alpha")
        expect(payload[:encrypted_data]).not_to include(job.job_id)
        expect(payload[:encrypted_data]).not_to include(job.class.name)
      end

      it "keeps scheduled_at outside the encrypted data for workflow replay" do
        scheduled_time = Time.utc(2024, 10, 20, 12, 0, 0)

        payload = described_class.from_job(job, scheduled_at: scheduled_time)

        expect(payload[:scheduled_at]).to eq(scheduled_time.iso8601)
        expect(payload[:encrypted_data]).not_to include(scheduled_time.iso8601)
      end

      it "decrypts payload metadata and arguments transparently" do
        payload = described_class.from_job(job)
        decrypted_payload = described_class.deserialize_payload(payload)

        expect(decrypted_payload).to include(
          job_class: job.class.name,
          job_id: job.job_id,
          queue_name: job.queue_name,
          executions: job.executions,
          exception_executions: job.exception_executions
        )
        expect(decrypted_payload[:arguments]).to eq(ActiveJob::Arguments.serialize(job.arguments))
        expect(described_class.deserialize_args(payload)).to eq(job.arguments)
      end

      it "binds v2 encrypted payloads to workflow context" do
        encryption_context = { namespace: "payments", workflow_id: "workflow-1" }
        payload = described_class.from_job(job, encryption_context: encryption_context)

        expect(payload).to include(
          encrypted_payload: true,
          encrypted_payload_version: 2,
          encrypted_key_id: "primary",
          encrypted_data: a_kind_of(String),
          encrypted_iv: a_kind_of(String),
          encrypted_auth_tag: a_kind_of(String)
        )
        expect(described_class.deserialize_payload(payload, encryption_context: encryption_context)).to include(
          job_class: job.class.name,
          job_id: job.job_id
        )

        expect do
          described_class.deserialize_payload(
            payload,
            encryption_context: { namespace: "payments", workflow_id: "workflow-2" }
          )
        end.to raise_error(ActiveJob::SerializationError, /Unable to decrypt ActiveJob::Temporal payload/)
      end

      it "pins v2 decryption to the encrypted key id" do
        old_key = encryption_key_for("old")
        new_key = encryption_key_for("new")
        encryption_context = { namespace: "payments", workflow_id: "workflow-1" }

        old_config = encrypted_configuration(key: { id: "old", key: old_key })
        payload = described_class.from_job(job, config: old_config, encryption_context: encryption_context)

        rotated_config = encrypted_configuration(key: { id: "new", key: new_key })
        rotated_config.encryption_old_keys = [{ id: "old", key: old_key }]
        expect(
          described_class.deserialize_args(payload, config: rotated_config, encryption_context: encryption_context)
        ).to eq(job.arguments)

        unknown_key_payload = payload.merge(encrypted_key_id: "missing")
        expect do
          described_class.deserialize_args(
            unknown_key_payload,
            config: rotated_config,
            encryption_context: encryption_context
          )
        end.to raise_error(ActiveJob::SerializationError, /Unknown encrypted payload key id/)

        rotated_config.encryption_old_keys = [{ id: "old", key: old_key, decrypt_until: Time.utc(2000, 1, 1) }]
        expect do
          described_class.deserialize_args(payload, config: rotated_config, encryption_context: encryption_context)
        end.to raise_error(ActiveJob::SerializationError, /expired/)

        rotated_config.encryption_old_keys = [{ id: "old", key: encryption_key_for("wrong") }]
        expect do
          described_class.deserialize_args(payload, config: rotated_config, encryption_context: encryption_context)
        end.to raise_error(ActiveJob::SerializationError, /Unable to decrypt ActiveJob::Temporal payload/)
      end

      it "does not trust rate limit metadata added outside encrypted data" do
        payload = described_class.from_job(job).merge(
          rate_limits: [
            { limit: 100, interval: 1.0, key: "global" }
          ]
        )

        decrypted_payload = described_class.deserialize_payload(payload)

        expect(decrypted_payload[:rate_limits]).to be_nil
      end

      it "does not trust chain metadata added outside encrypted data" do
        chain = [
          {
            job_class: "EncryptedChainNextJob",
            options: {
              queue: "reporting",
              priority: 7
            }
          }
        ]
        payload = described_class.from_job(job).merge(chain: chain)

        decrypted_payload = described_class.deserialize_payload(payload)

        expect(decrypted_payload[:chain]).to be_nil
      end

      it "emits encrypted payload size with plaintext labels" do
        payload = described_class.from_job(job)

        expect(ActiveJob::Temporal::Observability).to have_received(:emit).with(
          :payload_serialize,
          hash_including(
            job_class: job.class.name,
            queue: job.queue_name,
            bytes: JSON.generate(payload).bytesize
          )
        )
      end

      it "decrypts payloads encrypted with a rotated old key" do
        old_key = encryption_key_for("old")
        new_key = encryption_key_for("new")

        configure_payload_encryption(key: old_key)
        payload = described_class.from_job(job)

        configure_payload_encryption(key: new_key, old_keys: [old_key])

        expect(described_class.deserialize_args(payload)).to eq(job.arguments)
      end

      it "raises SerializationError when no configured key can decrypt the payload" do
        old_key = encryption_key_for("old")
        new_key = encryption_key_for("new")

        configure_payload_encryption(key: old_key)
        payload = described_class.from_job(job)
        configure_payload_encryption(key: new_key)

        expect { described_class.deserialize_args(payload) }
          .to raise_error(ActiveJob::SerializationError, /Unable to decrypt ActiveJob::Temporal payload/)
      end

      it "encrypts serialized MessagePack execution data and preserves workflow controls" do
        ActiveJob::Temporal.config.payload_serializer = :message_pack
        scheduled_time = Time.utc(2024, 10, 20, 12, 0, 0)

        payload = described_class.from_job(job, scheduled_at: scheduled_time, encrypt: false).merge(
          rate_limits: [{ limit: 100, interval: 1.0, key: "global" }],
          chain: [
            {
              job_class: "EncryptedSerializedChainNextJob",
              options: {
                queue: "reporting"
              }
            }
          ]
        )
        payload = described_class.encrypt_payload(payload)

        expect(payload).to include(
          encrypted_payload: true,
          encrypted_payload_version: 1,
          payload_serializer: "message_pack",
          payload_serializer_version: 1,
          encrypted_data: a_kind_of(String),
          scheduled_at: scheduled_time.iso8601
        )
        expect(payload).not_to have_key(:serialized_payload)
        expect(payload).not_to have_key(:serialized_data)
        expect(described_class.deserialize_payload(payload)).to include(
          job_class: job.class.name,
          job_id: job.job_id,
          queue_name: job.queue_name,
          scheduled_at: scheduled_time.iso8601,
          rate_limits: [{ "limit" => 100, "interval" => 1.0, "key" => "global" }],
          chain: [
            {
              "job_class" => "EncryptedSerializedChainNextJob",
              "options" => {
                "queue" => "reporting"
              }
            }
          ]
        )
        expect(described_class.deserialize_args(payload)).to eq(job.arguments)
      end
    end
  end

  describe "external payload storage" do
    it "offloads payloads that exceed the configured storage threshold" do
      adapter = memory_payload_storage_adapter
      job = SimpleJob.new(["x" * 2048])

      ActiveJob::Temporal.configure do |config|
        config.payload_storage_adapter = adapter
        config.payload_storage_threshold_kb = 1
      end

      payload = described_class.from_job(job, storage_metadata: { workflow_id: "workflow-1" })

      expect(payload).to include(
        external_payload: true,
        external_payload_version: 1,
        external_payload_reference: a_kind_of(String)
      )
      expect(payload).not_to have_key(:job_class)
      expect(adapter.metadata_for(payload.fetch(:external_payload_reference))).to include(workflow_id: "workflow-1")
      expect(described_class.deserialize_args(payload)).to eq(job.arguments)
    end

    it "stores encrypted transport payloads when payload encryption is enabled" do
      adapter = memory_payload_storage_adapter
      job = SimpleJob.new(["secret" * 500])
      encryption_context = { namespace: "payments", workflow_id: "workflow-1" }

      ActiveJob::Temporal.configure do |config|
        config.payload_storage_adapter = adapter
        config.payload_storage_threshold_kb = 1
      end
      configure_payload_encryption

      payload = described_class.from_job(
        job,
        encryption_context: encryption_context,
        storage_metadata: encryption_context
      )
      stored_payload = adapter.payload_for(payload.fetch(:external_payload_reference))

      expect(payload).to include(external_payload: true)
      expect(stored_payload).to include(encrypted_payload: true, encrypted_payload_version: 2)
      expect(stored_payload[:encrypted_data]).not_to include("secret")
      expect(described_class.deserialize_args(payload, encryption_context: encryption_context)).to eq(job.arguments)
    end

    it "keeps small payloads inline" do
      adapter = memory_payload_storage_adapter
      job = SimpleJob.new(["small"])

      ActiveJob::Temporal.configure do |config|
        config.payload_storage_adapter = adapter
        config.payload_storage_threshold_kb = 10
      end

      payload = described_class.from_job(job)

      expect(payload).to include(job_class: job.class.name)
      expect(payload).not_to include(external_payload: true)
      expect(adapter.references).to be_empty
    end

    it "raises a serialization error when external payloads cannot be loaded" do
      adapter = Class.new do
        def dump(_payload, metadata:); end

        def load(_reference)
          raise ActiveJob::SerializationError, "external payload is missing"
        end
      end.new

      ActiveJob::Temporal.configure do |config|
        config.payload_storage_adapter = adapter
        config.payload_storage_threshold_kb = 1
      end

      payload = {
        external_payload: true,
        external_payload_version: 1,
        external_payload_reference: "missing"
      }

      expect { described_class.deserialize_payload(payload) }
        .to raise_error(ActiveJob::SerializationError, /external payload is missing/)
    end

    it "lets transient external storage load errors retry the activity" do
      adapter = Class.new do
        def dump(_payload, metadata:); end

        def load(_reference)
          raise "storage timeout"
        end
      end.new

      ActiveJob::Temporal.configure do |config|
        config.payload_storage_adapter = adapter
        config.payload_storage_threshold_kb = 1
      end

      payload = {
        external_payload: true,
        external_payload_version: 1,
        external_payload_reference: "payload-1"
      }

      expect { described_class.deserialize_payload(payload) }
        .to raise_error(RuntimeError, /storage timeout/)
    end
  end

  describe ".deserialize_args" do
    it "round-trips job arguments" do
      job = SimpleJob.new(["string", 123, { foo: "bar" }])
      payload = described_class.from_job(job)

      expect(described_class.deserialize_args(payload)).to eq(job.arguments)
    end

    it "deserializes legacy payloads with top-level arguments" do
      job = SimpleJob.new(["legacy"])
      payload = {
        job_class: job.class.name,
        job_id: job.job_id,
        queue_name: job.queue_name,
        arguments: ActiveJob::Arguments.serialize(job.arguments)
      }

      expect(described_class.deserialize_args(payload)).to eq(job.arguments)
    end

    it "prefers canonical ActiveJob arguments when duplicate legacy arguments exist" do
      job_class = Class.new(ActiveJob::Base) do
        def self.name = "DuplicateArgumentsPayloadJob"
      end
      job = job_class.new("canonical")
      payload = described_class.from_job(job).merge(
        arguments: ActiveJob::Arguments.serialize(["legacy"])
      )

      expect(described_class.deserialize_args(payload)).to eq(["canonical"])
    end

    it "uses the provided config when deserializing encrypted arguments" do
      job = SimpleJob.new(["string", 123, { foo: "bar" }])
      config = encrypted_configuration(key: encryption_key_for("local"))
      payload = described_class.from_job(job, config: config)

      expect(described_class.deserialize_args(payload, config: config)).to eq(job.arguments)
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

  def job_for_payload_usage(target_usage, max_size_kb:)
    job_for_payload_size((max_size_kb * 1024 * target_usage).ceil)
  end

  def job_for_payload_size(target_bytes)
    baseline_job = SimpleJob.new([""])
    baseline_size = serialized_payload_size(baseline_job)
    argument_size = [target_bytes - baseline_size, 0].max
    job = SimpleJob.new(["x" * argument_size])

    return job if serialized_payload_size(job) == target_bytes

    raise "Unable to build payload with target size #{target_bytes}"
  end

  def serialized_payload_size(job)
    payload = {
      job_class: job.class.name,
      job_id: job.job_id,
      queue_name: job.queue_name,
      arguments: ActiveJob::Arguments.serialize(job.arguments || []),
      executions: job.executions || 0,
      exception_executions: job.exception_executions || {}
    }

    JSON.generate(payload).bytesize
  end

  def configure_payload_encryption(key: encryption_key_for("primary"), old_keys: [])
    ActiveJob::Temporal.configure do |config|
      config.encrypt_payload = true
      config.encryption_key = key
      config.encryption_old_keys = old_keys
    end
  end

  def encrypted_configuration(key:)
    ActiveJob::Temporal::Configuration.new.tap do |config|
      config.encryption_key = key
      config.encryption_old_keys = []
      config.encrypt_payload = true
    end
  end

  def encryption_key_for(label)
    Base64.strict_encode64(label.ljust(32, "-")[0, 32])
  end

  def memory_payload_storage_adapter
    MemoryPayloadStorageAdapter.new
  end
end
