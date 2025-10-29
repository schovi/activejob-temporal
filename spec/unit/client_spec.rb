# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal, ".client" do
  let(:tls_env_keys) do
    %w[TEMPORAL_TLS_CERT TEMPORAL_TLS_KEY TEMPORAL_TLS_SERVER_NAME]
  end

  around do |example|
    # Save original configuration state before resetting
    original_client = described_class.instance_variable_get(:@client)
    original_config = described_class.instance_variable_get(:@config)
    original_target = described_class.config&.target
    original_namespace = described_class.config&.namespace
    original_task_queue_prefix = described_class.config&.task_queue_prefix

    example.run
  ensure
    # Restore original configuration state after test completes
    described_class.instance_variable_set(:@client, original_client)
    described_class.instance_variable_set(:@config, original_config)
    if original_config
      described_class.configure do |config|
        config.target = original_target
        config.namespace = original_namespace
        config.task_queue_prefix = original_task_queue_prefix
      end
    end
  end

  before do
    # Reset instance variables and stub Temporal client for each test
    described_class.instance_variable_set(:@client, nil)
    described_class.instance_variable_set(:@config, nil)
    stub_const("Temporalio::Client", class_double("Temporalio::Client"))
  end

  around do |example|
    original_env = {}
    tls_env_keys.each do |key|
      original_env[key] = ENV.fetch(key, nil)
      ENV.delete(key)
    end

    example.run
  ensure
    original_env.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  it "creates a Temporal client using configuration values" do
    described_class.configure do |config|
      config.target = "localhost:7233"
      config.namespace = "custom"
    end

    client_instance = instance_double("Temporalio::Client")
    expect(Temporalio::Client).to receive(:connect).with(
      "localhost:7233",
      "custom"
    ).and_return(client_instance)

    expect(described_class.client).to be(client_instance)
  end

  it "memoizes the client instance" do
    configured_client = instance_double("Temporalio::Client")
    allow(Temporalio::Client).to receive(:connect).and_return(configured_client)

    first_call = described_class.client
    second_call = described_class.client

    expect(first_call).to be(second_call)
    expect(Temporalio::Client).to have_received(:connect).once
  end

  it "passes optional TLS options when provided via environment variables" do
    ENV["TEMPORAL_TLS_CERT"] = "cert-data"
    ENV["TEMPORAL_TLS_KEY"] = "key-data"
    ENV["TEMPORAL_TLS_SERVER_NAME"] = "temporal.example.dev"

    client_instance = instance_double("Temporalio::Client")
    expect(Temporalio::Client).to receive(:connect) do |target, namespace, **kwargs|
      expect(target).to eq("127.0.0.1:7233")
      expect(namespace).to eq("default")
      expect(kwargs[:tls]).to eq(
        certificate: "cert-data",
        private_key: "key-data",
        server_name: "temporal.example.dev"
      )
      client_instance
    end

    expect(described_class.client).to be(client_instance)
  end

  it "compacts TLS options when only some environment variables are set" do
    ENV["TEMPORAL_TLS_CERT"] = "cert-data"

    client_instance = instance_double("Temporalio::Client")
    expect(Temporalio::Client).to receive(:connect) do |target, namespace, **kwargs|
      expect(target).to eq("127.0.0.1:7233")
      expect(namespace).to eq("default")
      expect(kwargs[:tls]).to eq(certificate: "cert-data")
      client_instance
    end

    expect(described_class.client).to be(client_instance)
  end

  it "prefers TLS configuration defined on the config object" do
    described_class.configure do |config|
      config.target = "localhost:7233"
      config.namespace = "custom"
    end
    configuration = ActiveJob::Temporal.config
    configuration.singleton_class.class_eval { attr_accessor :tls } unless configuration.respond_to?(:tls)
    configuration.tls = {
      certificate: "config-cert",
      private_key: "config-key"
    }

    client_instance = instance_double("Temporalio::Client")
    expect(Temporalio::Client).to receive(:connect) do |target, namespace, **kwargs|
      expect(target).to eq("localhost:7233")
      expect(namespace).to eq("custom")
      expect(kwargs[:tls]).to eq(
        certificate: "config-cert",
        private_key: "config-key"
      )
      client_instance
    end

    expect(described_class.client).to be(client_instance)
  ensure
    configuration&.tls = nil
  end

  it "wraps connection errors in ActiveJob::Temporal::Error" do
    described_class.configure do |config|
      config.target = "1.2.3.4:7233"
      config.namespace = "production"
    end

    allow(Temporalio::Client).to receive(:connect).and_raise(StandardError, "unreachable")

    expect do
      described_class.client
    end.to raise_error(ActiveJob::Temporal::Error, /Unable to connect to Temporal at 1\.2\.3\.4:7233/)
  end
end
