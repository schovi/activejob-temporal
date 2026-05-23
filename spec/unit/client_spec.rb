# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe ActiveJob::Temporal, ".client" do
  let(:tls_env_keys) do
    %w[TEMPORAL_TLS_CERT TEMPORAL_TLS_KEY TEMPORAL_TLS_SERVER_NAME TEMPORAL_TLS_SERVER_ROOT_CA_CERT]
  end

  def expect_tls_options(tls, client_cert: nil, client_private_key: nil, server_root_ca_cert: nil, domain: nil)
    expect(tls.client_cert).to eq(client_cert)
    expect(tls.client_private_key).to eq(client_private_key)
    expect(tls.server_root_ca_cert).to eq(server_root_ca_cert)
    expect(tls.domain).to eq(domain)
  end

  around do |example|
    # Save original configuration state before resetting
    original_client = described_class.instance_variable_get(:@client)
    original_config_mvar = described_class.instance_variable_get(:@config_mvar)
    original_target = described_class.config&.target
    original_namespace = described_class.config&.namespace
    original_task_queue_prefix = described_class.config&.task_queue_prefix

    example.run
  ensure
    # Restore original configuration state after test completes
    described_class.instance_variable_set(:@client, original_client)
    described_class.instance_variable_set(:@config_mvar, original_config_mvar)
    if original_config_mvar
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
    described_class.instance_variable_set(:@config_mvar, nil)
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

  it "reloads the memoized client with a fresh connection" do
    first_client = instance_double("Temporalio::Client")
    second_client = instance_double("Temporalio::Client")
    allow(Temporalio::Client).to receive(:connect).and_return(first_client, second_client)

    expect(described_class.client).to be(first_client)
    expect(described_class.reload_client!).to be(second_client)
    expect(described_class.client).to be(second_client)
    expect(Temporalio::Client).to have_received(:connect).twice
  end

  it "closes the previous client after a successful reload when supported" do
    first_client = double("Temporalio::Client", close: true)
    second_client = double("Temporalio::Client", close: true)
    allow(Temporalio::Client).to receive(:connect).and_return(first_client, second_client)

    described_class.client
    described_class.reload_client!

    expect(first_client).to have_received(:close)
    expect(second_client).not_to have_received(:close)
  end

  it "keeps the previous client when reload connection fails" do
    configured_client = instance_double("Temporalio::Client")
    allow(Temporalio::Client).to receive(:connect).and_return(configured_client)
    described_class.client

    allow(Temporalio::Client).to receive(:connect).and_raise(StandardError, "unreachable")

    expect { described_class.reload_client! }.to raise_error(ActiveJob::Temporal::Error)
    expect(described_class.client).to be(configured_client)
  end

  it "keeps the previous client when the reload block fails" do
    first_client = double("Temporalio::Client", close: true)
    second_client = double("Temporalio::Client", close: true)
    allow(Temporalio::Client).to receive(:connect).and_return(first_client, second_client)
    described_class.client

    expect do
      described_class.reload_client! { raise "worker replacement failed" }
    end.to raise_error(RuntimeError, /worker replacement failed/)
    expect(described_class.client).to be(first_client)
    expect(first_client).not_to have_received(:close)
    expect(second_client).to have_received(:close)
  end

  it "passes optional TLS options when provided via environment variables" do
    ENV["TEMPORAL_TLS_CERT"] = "cert-data"
    ENV["TEMPORAL_TLS_KEY"] = "key-data"
    ENV["TEMPORAL_TLS_SERVER_NAME"] = "temporal.example.dev"

    client_instance = instance_double("Temporalio::Client")
    expect(Temporalio::Client).to receive(:connect) do |target, namespace, **kwargs|
      expect(target).to eq("127.0.0.1:7233")
      expect(namespace).to eq("default")
      expect_tls_options(
        kwargs[:tls],
        client_cert: "cert-data",
        client_private_key: "key-data",
        domain: "temporal.example.dev"
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
      expect_tls_options(kwargs[:tls], client_cert: "cert-data")
      client_instance
    end

    expect(described_class.client).to be(client_instance)
  end

  it "handles only TLS key being set" do
    ENV["TEMPORAL_TLS_KEY"] = "key-only"

    client_instance = instance_double("Temporalio::Client")
    expect(Temporalio::Client).to receive(:connect) do |target, namespace, **kwargs|
      expect(target).to eq("127.0.0.1:7233")
      expect(namespace).to eq("default")
      expect_tls_options(kwargs[:tls], client_private_key: "key-only")
      client_instance
    end

    expect(described_class.client).to be(client_instance)
  end

  it "handles only TLS server_name being set" do
    ENV["TEMPORAL_TLS_SERVER_NAME"] = "temporal.example.com"

    client_instance = instance_double("Temporalio::Client")
    expect(Temporalio::Client).to receive(:connect) do |target, namespace, **kwargs|
      expect(target).to eq("127.0.0.1:7233")
      expect(namespace).to eq("default")
      expect_tls_options(kwargs[:tls], domain: "temporal.example.com")
      client_instance
    end

    expect(described_class.client).to be(client_instance)
  end

  it "passes optional TLS root CA when provided via environment variables" do
    ENV["TEMPORAL_TLS_SERVER_ROOT_CA_CERT"] = "root-ca-data"

    client_instance = instance_double("Temporalio::Client")
    expect(Temporalio::Client).to receive(:connect) do |_target, _namespace, **kwargs|
      expect_tls_options(kwargs[:tls], server_root_ca_cert: "root-ca-data")
      client_instance
    end

    expect(described_class.client).to be(client_instance)
  end

  it "prefers TLS configuration defined on the config object" do
    described_class.configure do |config|
      config.target = "localhost:7233"
      config.namespace = "custom"
      config.tls = {
        certificate: "config-cert",
        private_key: "config-key"
      }
    end

    client_instance = instance_double("Temporalio::Client")
    expect(Temporalio::Client).to receive(:connect) do |target, namespace, **kwargs|
      expect(target).to eq("localhost:7233")
      expect(namespace).to eq("custom")
      expect_tls_options(
        kwargs[:tls],
        client_cert: "config-cert",
        client_private_key: "config-key"
      )
      client_instance
    end

    expect(described_class.client).to be(client_instance)
  end

  it "allows TLS to be explicitly disabled on the config object" do
    ENV["TEMPORAL_TLS_CERT"] = "cert-data"

    described_class.configure do |config|
      config.tls = false
    end

    client_instance = instance_double("Temporalio::Client")
    expect(Temporalio::Client).to receive(:connect) do |_target, _namespace, **kwargs|
      expect(kwargs).to eq(tls: false)
      client_instance
    end

    expect(described_class.client).to be(client_instance)
  end

  it "passes SDK-native TLS options through unchanged" do
    tls_options = ActiveJob::Temporal::Client::TLS_OPTIONS_CLASS.new(client_cert: "sdk-cert")

    described_class.configure do |config|
      config.tls = tls_options
    end

    client_instance = instance_double("Temporalio::Client")
    expect(Temporalio::Client).to receive(:connect) do |_target, _namespace, **kwargs|
      expect(kwargs[:tls]).to be(tls_options)
      client_instance
    end

    expect(described_class.client).to be(client_instance)
  end

  it "reads TLS certificate files when path configuration is present" do
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, "client.pem")
      key_path = File.join(directory, "client-key.pem")
      root_ca_path = File.join(directory, "root-ca.pem")
      File.write(cert_path, "cert-from-file")
      File.write(key_path, "key-from-file")
      File.write(root_ca_path, "root-ca-from-file")

      described_class.configure do |config|
        config.tls_cert_path = cert_path
        config.tls_key_path = key_path
        config.tls_server_root_ca_cert_path = root_ca_path
        config.tls_domain = "temporal.example.dev"
      end

      client_instance = instance_double("Temporalio::Client")
      expect(Temporalio::Client).to receive(:connect) do |_target, _namespace, **kwargs|
        expect_tls_options(
          kwargs[:tls],
          client_cert: "cert-from-file",
          client_private_key: "key-from-file",
          server_root_ca_cert: "root-ca-from-file",
          domain: "temporal.example.dev"
        )
        client_instance
      end

      expect(described_class.client).to be(client_instance)
    end
  end

  it "rejects TLS files replaced by symlinks after configuration validation" do
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, "client.pem")
      key_path = File.join(directory, "client-key.pem")
      File.write(cert_path, "cert-from-file")
      File.write(key_path, "key-from-file")

      described_class.configure do |config|
        config.tls_cert_path = cert_path
        config.tls_key_path = key_path
      end
      File.delete(cert_path)
      File.symlink(key_path, cert_path)

      expect(Temporalio::Client).not_to receive(:connect)
      expect { described_class.client }
        .to raise_error(ActiveJob::Temporal::Error, /TLS file path must not be a symlink/)
    end
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

  context "TLS certificate error handling" do
    it "wraps OpenSSL certificate errors with descriptive message" do
      require "openssl"

      described_class.configure do |config|
        config.target = "temporal.example.com:7233"
        config.namespace = "default"
      end

      allow(Temporalio::Client).to receive(:connect)
        .and_raise(OpenSSL::X509::CertificateError, "invalid certificate format")

      expect do
        described_class.client
      end.to raise_error(ActiveJob::Temporal::Error, /Unable to connect to Temporal/)
    end

    it "wraps socket errors when target is unreachable" do
      described_class.configure do |config|
        config.target = "invalid.temporal.example.com:7233"
        config.namespace = "default"
      end

      allow(Temporalio::Client).to receive(:connect)
        .and_raise(SocketError, "getaddrinfo: nodename nor servname provided")

      expect do
        described_class.client
      end.to raise_error(ActiveJob::Temporal::Error, /Unable to connect to Temporal/)
    end

    it "wraps connection refused errors with descriptive message" do
      described_class.configure do |config|
        config.target = "localhost:7233"
        config.namespace = "default"
      end

      allow(Temporalio::Client).to receive(:connect)
        .and_raise(Errno::ECONNREFUSED, "Connection refused")

      expect do
        described_class.client
      end.to raise_error(ActiveJob::Temporal::Error, /Unable to connect to Temporal at localhost:7233/)
    end

    it "wraps timeout errors when connection takes too long" do
      described_class.configure do |config|
        config.target = "slow.temporal.example.com:7233"
        config.namespace = "default"
      end

      allow(Temporalio::Client).to receive(:connect)
        .and_raise(Errno::ETIMEDOUT, "Connection timed out")

      expect do
        described_class.client
      end.to raise_error(ActiveJob::Temporal::Error, /Unable to connect to Temporal/)
    end
  end
end
