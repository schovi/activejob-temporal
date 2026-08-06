# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

module ClientSpecSupport
  class FakeClient
    attr_reader :close_count

    def initialize
      @close_count = 0
    end

    def close
      @close_count += 1
      nil
    end
  end
end

describe ActiveJob::Temporal, ".client" do
  let(:tls_env_keys) do
    %w[TEMPORAL_TLS_CERT TEMPORAL_TLS_KEY TEMPORAL_TLS_SERVER_NAME TEMPORAL_TLS_SERVER_ROOT_CA_CERT]
  end

  around do |example|
    original_client = described_class.instance_variable_get(:@client)
    original_config_mvar = described_class.instance_variable_get(:@config_mvar)
    original_target = described_class.config&.target
    original_namespace = described_class.config&.namespace
    original_task_queue_prefix = described_class.config&.task_queue_prefix

    example.run
  ensure
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
    described_class.instance_variable_set(:@client, nil)
    described_class.instance_variable_set(:@config_mvar, nil)
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
    client_instance = fake_client
    stub_connect(client_instance)

    assert_same client_instance, described_class.client
    assert_equal ["localhost:7233", "custom"], connect_call.arguments
  end

  it "memoizes the client instance" do
    configured_client = fake_client
    stub_connect(configured_client)

    first_call = described_class.client
    second_call = described_class.client

    assert_same first_call, second_call
    assert_equal 1, connect_calls.size
  end

  it "reloads the memoized client with a fresh connection" do
    first_client = fake_client
    second_client = fake_client
    stub_connect(first_client, second_client)

    assert_same first_client, described_class.client
    assert_same second_client, described_class.reload_client!
    assert_same second_client, described_class.client
    assert_equal 2, connect_calls.size
  end

  it "closes the previous client after a successful reload when supported" do
    first_client = fake_client
    second_client = fake_client
    stub_connect(first_client, second_client)

    described_class.client
    described_class.reload_client!

    assert_equal 1, first_client.close_count
    assert_equal 0, second_client.close_count
  end

  it "keeps the previous client when reload connection fails" do
    configured_client = fake_client
    connection_results = [configured_client]
    stub_connect do
      raise StandardError, "unreachable" if connection_results.empty?

      connection_results.shift
    end
    described_class.client

    assert_raises(ActiveJob::Temporal::Error) { described_class.reload_client! }
    assert_same configured_client, described_class.client
  end

  it "keeps the previous client when the reload block fails" do
    first_client = fake_client
    second_client = fake_client
    stub_connect(first_client, second_client)
    described_class.client

    error = assert_raises(RuntimeError) do
      described_class.reload_client! { raise "worker replacement failed" }
    end

    assert_match(/worker replacement failed/, error.message)
    assert_same first_client, described_class.client
    assert_equal 0, first_client.close_count
    assert_equal 1, second_client.close_count
  end

  it "passes optional TLS options when provided via environment variables" do
    ENV["TEMPORAL_TLS_CERT"] = "cert-data"
    ENV["TEMPORAL_TLS_KEY"] = "key-data"
    ENV["TEMPORAL_TLS_SERVER_NAME"] = "temporal.example.dev"
    client_instance = fake_client
    stub_connect(client_instance)

    assert_same client_instance, described_class.client
    assert_equal ["127.0.0.1:7233", "default"], connect_call.arguments
    assert_tls_options(
      connect_call.keywords[:tls],
      client_cert: "cert-data",
      client_private_key: "key-data",
      domain: "temporal.example.dev"
    )
  end

  it "compacts TLS options when only some environment variables are set" do
    ENV["TEMPORAL_TLS_CERT"] = "cert-data"
    client_instance = fake_client
    stub_connect(client_instance)

    assert_same client_instance, described_class.client
    assert_equal ["127.0.0.1:7233", "default"], connect_call.arguments
    assert_tls_options(connect_call.keywords[:tls], client_cert: "cert-data")
  end

  it "handles only TLS key being set" do
    ENV["TEMPORAL_TLS_KEY"] = "key-only"
    client_instance = fake_client
    stub_connect(client_instance)

    assert_same client_instance, described_class.client
    assert_equal ["127.0.0.1:7233", "default"], connect_call.arguments
    assert_tls_options(connect_call.keywords[:tls], client_private_key: "key-only")
  end

  it "handles only TLS server_name being set" do
    ENV["TEMPORAL_TLS_SERVER_NAME"] = "temporal.example.com"
    client_instance = fake_client
    stub_connect(client_instance)

    assert_same client_instance, described_class.client
    assert_equal ["127.0.0.1:7233", "default"], connect_call.arguments
    assert_tls_options(connect_call.keywords[:tls], domain: "temporal.example.com")
  end

  it "passes optional TLS root CA when provided via environment variables" do
    ENV["TEMPORAL_TLS_SERVER_ROOT_CA_CERT"] = "root-ca-data"
    client_instance = fake_client
    stub_connect(client_instance)

    assert_same client_instance, described_class.client
    assert_tls_options(connect_call.keywords[:tls], server_root_ca_cert: "root-ca-data")
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
    client_instance = fake_client
    stub_connect(client_instance)

    assert_same client_instance, described_class.client
    assert_equal ["localhost:7233", "custom"], connect_call.arguments
    assert_tls_options(
      connect_call.keywords[:tls],
      client_cert: "config-cert",
      client_private_key: "config-key"
    )
  end

  it "allows TLS to be explicitly disabled on the config object" do
    ENV["TEMPORAL_TLS_CERT"] = "cert-data"
    described_class.configure do |config|
      config.tls = false
    end
    client_instance = fake_client
    stub_connect(client_instance)

    assert_same client_instance, described_class.client
    assert_equal({ tls: false }, connect_call.keywords)
  end

  it "passes SDK-native TLS options through unchanged" do
    tls_options = ActiveJob::Temporal::Client::TLS_OPTIONS_CLASS.new(client_cert: "sdk-cert")
    described_class.configure do |config|
      config.tls = tls_options
    end
    client_instance = fake_client
    stub_connect(client_instance)

    assert_same client_instance, described_class.client
    assert_same tls_options, connect_call.keywords[:tls]
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
      client_instance = fake_client
      stub_connect(client_instance)

      assert_same client_instance, described_class.client
      assert_tls_options(
        connect_call.keywords[:tls],
        client_cert: "cert-from-file",
        client_private_key: "key-from-file",
        server_root_ca_cert: "root-ca-from-file",
        domain: "temporal.example.dev"
      )
    end
  end

  it "rejects TLS files replaced by a non-regular file after configuration validation" do
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
      File.symlink(directory, cert_path)
      stub_connect(fake_client)

      error = assert_raises(ActiveJob::Temporal::Error) { described_class.client }
      assert_match(/TLS file path must point to a regular file/, error.message)
      assert_empty connect_calls
    end
  end

  it "wraps connection errors in ActiveJob::Temporal::TemporalConnectionError" do
    described_class.configure do |config|
      config.target = "1.2.3.4:7233"
      config.namespace = "production"
    end
    stub_connect(error: StandardError.new("unreachable"))

    error = assert_raises(ActiveJob::Temporal::TemporalConnectionError) { described_class.client }
    assert_match(/Unable to connect to Temporal at 1\.2\.3\.4:7233/, error.message)
    assert_kind_of ActiveJob::Temporal::Error, error
  end

  describe "TLS certificate error handling" do
    it "wraps OpenSSL certificate errors with descriptive message" do
      require "openssl"

      described_class.configure do |config|
        config.target = "temporal.example.com:7233"
        config.namespace = "default"
      end
      stub_connect(error: OpenSSL::X509::CertificateError.new("invalid certificate format"))

      error = assert_raises(ActiveJob::Temporal::Error) { described_class.client }
      assert_match(/Unable to connect to Temporal/, error.message)
    end

    it "wraps socket errors when target is unreachable" do
      described_class.configure do |config|
        config.target = "invalid.temporal.example.com:7233"
        config.namespace = "default"
      end
      stub_connect(error: SocketError.new("getaddrinfo: nodename nor servname provided"))

      error = assert_raises(ActiveJob::Temporal::Error) { described_class.client }
      assert_match(/Unable to connect to Temporal/, error.message)
    end

    it "wraps connection refused errors with descriptive message" do
      described_class.configure do |config|
        config.target = "localhost:7233"
        config.namespace = "default"
      end
      stub_connect(error: Errno::ECONNREFUSED.new("Connection refused"))

      error = assert_raises(ActiveJob::Temporal::Error) { described_class.client }
      assert_match(/Unable to connect to Temporal at localhost:7233/, error.message)
    end

    it "wraps timeout errors when connection takes too long" do
      described_class.configure do |config|
        config.target = "slow.temporal.example.com:7233"
        config.namespace = "default"
      end
      stub_connect(error: Errno::ETIMEDOUT.new("Connection timed out"))

      error = assert_raises(ActiveJob::Temporal::Error) { described_class.client }
      assert_match(/Unable to connect to Temporal/, error.message)
    end
  end

  private

  def assert_tls_options(tls, client_cert: nil, client_private_key: nil, server_root_ca_cert: nil, domain: nil)
    assert_tls_value client_cert, tls.client_cert
    assert_tls_value client_private_key, tls.client_private_key
    assert_tls_value server_root_ca_cert, tls.server_root_ca_cert
    assert_tls_value domain, tls.domain
  end

  def assert_tls_value(expected, actual)
    return assert_nil actual if expected.nil?

    assert_equal expected, actual
  end

  def fake_client
    ClientSpecSupport::FakeClient.new
  end

  def stub_connect(*results, error: nil, &implementation)
    result_queue = results.dup
    @connect_recorder = call_recorded_method(Temporalio::Client, :connect) do |target, namespace, **keywords|
      raise error if error

      if implementation
        implementation.call(target, namespace, **keywords)
      else
        result_queue.shift
      end
    end
  end

  def connect_calls
    @connect_recorder.calls_for(:connect)
  end

  def connect_call(index = 0)
    connect_calls.fetch(index)
  end
end
