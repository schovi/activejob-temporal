# frozen_string_literal: true

require "spec_helper"

describe ActiveJob::Temporal::PayloadSerializers do
  let(:payload) do
    {
      job_class: "SerializerSpecJob",
      job_id: "job-1",
      queue_name: "default",
      arguments: [{ "_aj_serialized" => "ActiveJob::Serializers::ObjectSerializer" }],
      executions: 0,
      exception_executions: {}
    }
  end

  it "keeps JSON as the legacy inline payload format" do
    serializer = described_class.fetch(:json)

    refute serializer.envelope?(payload)
    assert_equal payload, serializer.dump(payload)
    assert_equal payload, serializer.load(payload)
  end

  it "round-trips payloads through MessagePack envelopes" do
    serializer = described_class.fetch(:message_pack)
    envelope = serializer.dump(payload)

    assert_equal true, envelope.fetch(:serialized_payload)
    assert_equal "message_pack", envelope.fetch(:payload_serializer)
    assert_equal 1, envelope.fetch(:payload_serializer_version)
    assert_kind_of String, envelope.fetch(:serialized_data)
    refute envelope.key?(:job_class)
    assert_equal payload, serializer.load(envelope)
  end

  it "raises a configuration error when MessagePack is not installed" do
    serializer = described_class.fetch(:message_pack)
    call_recorded_method(serializer, :require, raises: LoadError.new)

    error = assert_raises(ActiveJob::Temporal::ConfigurationError) { serializer.dump(payload) }
    assert_match(/add gem "msgpack"/, error.message)
  end

  it "accepts msgpack as an alias for message_pack" do
    assert_same described_class.fetch(:message_pack), described_class.fetch(:msgpack)
  end

  it "round-trips payloads through Marshal envelopes" do
    serializer = described_class.fetch(:marshal)
    envelope = serializer.dump(payload)

    assert_equal true, envelope.fetch(:serialized_payload)
    assert_equal "marshal", envelope.fetch(:payload_serializer)
    assert_equal 1, envelope.fetch(:payload_serializer_version)
    assert_kind_of String, envelope.fetch(:serialized_data)
    refute envelope.key?(:job_class)
    assert_equal payload, serializer.load(envelope)
  end

  it "rejects unknown serializers" do
    error = assert_raises(ActiveJob::Temporal::ConfigurationError) { described_class.fetch(:yaml) }
    assert_match(/Unsupported payload serializer/, error.message)
  end
end
