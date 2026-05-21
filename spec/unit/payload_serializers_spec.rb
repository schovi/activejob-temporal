# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::PayloadSerializers do
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

    expect(serializer.envelope?(payload)).to be(false)
    expect(serializer.dump(payload)).to eq(payload)
    expect(serializer.load(payload)).to eq(payload)
  end

  it "round-trips payloads through MessagePack envelopes" do
    serializer = described_class.fetch(:message_pack)
    envelope = serializer.dump(payload)

    expect(envelope).to include(
      serialized_payload: true,
      payload_serializer: "message_pack",
      payload_serializer_version: 1,
      serialized_data: a_kind_of(String)
    )
    expect(envelope).not_to have_key(:job_class)
    expect(serializer.load(envelope)).to eq(payload)
  end

  it "raises a configuration error when MessagePack is not installed" do
    serializer = described_class.fetch(:message_pack)
    allow(serializer).to receive(:require).with("msgpack").and_raise(LoadError)

    expect { serializer.dump(payload) }
      .to raise_error(ActiveJob::Temporal::ConfigurationError, /add gem "msgpack"/)
  end

  it "accepts msgpack as an alias for message_pack" do
    expect(described_class.fetch(:msgpack)).to be(described_class.fetch(:message_pack))
  end

  it "round-trips payloads through Marshal envelopes" do
    serializer = described_class.fetch(:marshal)
    envelope = serializer.dump(payload)

    expect(envelope).to include(
      serialized_payload: true,
      payload_serializer: "marshal",
      payload_serializer_version: 1,
      serialized_data: a_kind_of(String)
    )
    expect(envelope).not_to have_key(:job_class)
    expect(serializer.load(envelope)).to eq(payload)
  end

  it "rejects unknown serializers" do
    expect { described_class.fetch(:yaml) }
      .to raise_error(ActiveJob::Temporal::ConfigurationError, /Unsupported payload serializer/)
  end
end
