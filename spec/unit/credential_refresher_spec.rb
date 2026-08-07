# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "activejob/temporal/credential_refresher"

module CredentialRefresherSpecSupport
  FakeListener = Struct.new(:directories, :options, :callback, :started, :stopped) do
    def start
      self.started = true
      self
    end

    def stop
      self.stopped = true
    end
  end

  class ListenerFactory
    attr_reader :listener

    def to(*directories, **options, &callback)
      @listener = FakeListener.new(directories, options, callback, false, false)
    end
  end

  class UnavailableListenerFactory
    def to(*)
      raise LoadError, "cannot load such file -- listen"
    end
  end

  class RecordingLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def log_event(name, attributes = {})
      @events << [name, attributes]
    end
    alias warn log_event
    alias error log_event

    def names
      @events.map(&:first)
    end
  end

  ConfigStub = Struct.new(
    :tls_cert_path,
    :tls_key_path,
    :tls_server_root_ca_cert_path,
    :tls_cert_watch,
    :api_key_file,
    :api_key_watch,
    :credential_poll_interval,
    :credential_file_events,
    keyword_init: true
  )
end

describe ActiveJob::Temporal::CredentialRefresher do
  def source(paths, on_change, name: "test")
    ActiveJob::Temporal::CredentialRefresher::Source.new(
      name: name,
      paths: Array(paths),
      on_change: on_change
    )
  end

  # Splatted rather than Array()-wrapped: Struct#to_a would flatten a Source into its members.
  def build_refresher(*sources, **)
    ActiveJob::Temporal::CredentialRefresher.new(
      sources: sources,
      logger: CredentialRefresherSpecSupport::RecordingLogger.new,
      **
    )
  end

  it "fires the callback when file content changes" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "token")
      File.write(path, "first")
      reloads = []
      refresher = build_refresher(source(path, -> { reloads << :reload })).start

      File.write(path, "second")
      refresher.refresh_changed_sources

      assert_equal [:reload], reloads
    ensure
      refresher.stop
    end
  end

  it "does not fire when only the mtime changes" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "token")
      File.write(path, "same")
      reloads = []
      refresher = build_refresher(source(path, -> { reloads << :reload })).start

      File.write(path, "same")
      refresher.refresh_changed_sources

      assert_empty reloads
    ensure
      refresher.stop
    end
  end

  it "reads through the symlink chain of a Kubernetes projected volume" do
    Dir.mktmpdir do |directory|
      versioned = File.join(directory, "..2026_08_07_09_09_14.1636744838")
      Dir.mkdir(versioned)
      File.write(File.join(versioned, "token"), "first")
      File.symlink(versioned, File.join(directory, "..data"))
      token_path = File.join(directory, "token")
      File.symlink(File.join(directory, "..data", "token"), token_path)

      reloads = []
      refresher = build_refresher(source(token_path, -> { reloads << :reload })).start

      rotated = File.join(directory, "..2026_08_07_10_09_14.1636744839")
      Dir.mkdir(rotated)
      File.write(File.join(rotated, "token"), "second")
      File.unlink(File.join(directory, "..data"))
      File.symlink(rotated, File.join(directory, "..data"))
      refresher.refresh_changed_sources

      assert_equal [:reload], reloads
    ensure
      refresher.stop
    end
  end

  it "fires once when a cert and key pair rotate together" do
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, "client.pem")
      key_path = File.join(directory, "client-key.pem")
      File.write(cert_path, "cert")
      File.write(key_path, "key")
      reloads = []
      refresher = build_refresher(source([cert_path, key_path], -> { reloads << :reload })).start

      File.write(cert_path, "new cert")
      File.write(key_path, "new key")
      refresher.refresh_changed_sources

      assert_equal [:reload], reloads
    ensure
      refresher.stop
    end
  end

  it "retries on the next check when the callback raises" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "token")
      File.write(path, "first")
      attempts = []
      refresher = build_refresher(
        source(path, lambda {
          attempts << :attempt
          raise "reload failed" if attempts.size == 1
        })
      ).start

      File.write(path, "second")
      refresher.refresh_changed_sources
      refresher.refresh_changed_sources

      assert_equal %i[attempt attempt], attempts
    ensure
      refresher.stop
    end
  end

  it "skips an unreadable path and fires once it becomes readable again" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "token")
      File.write(path, "first")
      reloads = []
      refresher = build_refresher(source(path, -> { reloads << :reload })).start

      File.unlink(path)
      refresher.refresh_changed_sources

      assert_empty reloads

      File.write(path, "second")
      refresher.refresh_changed_sources

      assert_equal [:reload], reloads
    ensure
      refresher.stop
    end
  end

  it "does not fire on the first check when nothing rotated" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "token")
      File.write(path, "first")
      reloads = []
      refresher = build_refresher(source(path, -> { reloads << :reload })).start

      refresher.refresh_changed_sources

      assert_empty reloads
    ensure
      refresher.stop
    end
  end

  it "checks immediately when a filesystem event wakes the loop" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "token")
      File.write(path, "first")
      reloads = Queue.new
      factory = CredentialRefresherSpecSupport::ListenerFactory.new
      refresher = build_refresher(
        source(path, -> { reloads << :reload }),
        poll_interval: 60,
        file_events: true,
        listener_factory: factory
      ).start

      File.write(path, "second")
      factory.listener.callback.call([path], [], [])

      assert_equal :reload, reloads.pop(timeout: 5)
    ensure
      refresher.stop
    end
  end

  it "watches each credential directory once and skips kubelet's versioned copies" do
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, "client.pem")
      key_path = File.join(directory, "client-key.pem")
      File.write(cert_path, "cert")
      File.write(key_path, "key")
      factory = CredentialRefresherSpecSupport::ListenerFactory.new
      refresher = build_refresher(
        source([cert_path, key_path], -> {}),
        file_events: true,
        listener_factory: factory
      ).start

      assert_equal [directory], factory.listener.directories
      assert_equal(
        ActiveJob::Temporal::CredentialRefresher::KUBERNETES_VERSIONED_DIR,
        factory.listener.options[:ignore]
      )
      assert factory.listener.started
    ensure
      refresher.stop
    end
  end

  it "keeps polling when the listen gem is unavailable" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "token")
      File.write(path, "first")
      reloads = []
      logger = CredentialRefresherSpecSupport::RecordingLogger.new
      refresher = ActiveJob::Temporal::CredentialRefresher.new(
        sources: [source(path, -> { reloads << :reload })],
        file_events: true,
        logger: logger,
        listener_factory: CredentialRefresherSpecSupport::UnavailableListenerFactory.new
      ).start

      assert_includes logger.names, "credential_file_events_unavailable"

      File.write(path, "second")
      refresher.refresh_changed_sources

      assert_equal [:reload], reloads
    ensure
      refresher.stop
    end
  end

  it "stops the listener" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "token")
      File.write(path, "first")
      factory = CredentialRefresherSpecSupport::ListenerFactory.new
      refresher = build_refresher(
        source(path, -> {}),
        file_events: true,
        listener_factory: factory
      ).start

      refresher.stop

      assert factory.listener.stopped
    end
  end

  it "builds no sources when both watch flags are off" do
    config = CredentialRefresherSpecSupport::ConfigStub.new(
      tls_cert_watch: false,
      api_key_watch: false,
      credential_poll_interval: 30,
      credential_file_events: false
    )
    reloads = []

    refresher = described_class.from_config(
      config,
      on_tls_change: -> { reloads << :tls },
      on_api_key_change: -> { reloads << :api_key }
    ).start
    refresher.refresh_changed_sources

    assert_empty reloads
  end

  it "builds one TLS source and one API key source from configuration" do
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, "client.pem")
      key_path = File.join(directory, "client-key.pem")
      token_path = File.join(directory, "token")
      [cert_path, key_path, token_path].each { |path| File.write(path, "first") }

      config = CredentialRefresherSpecSupport::ConfigStub.new(
        tls_cert_path: cert_path,
        tls_key_path: key_path,
        tls_server_root_ca_cert_path: nil,
        tls_cert_watch: true,
        api_key_file: token_path,
        api_key_watch: true,
        credential_poll_interval: 30,
        credential_file_events: false
      )
      reloads = []
      refresher = described_class.from_config(
        config,
        on_tls_change: -> { reloads << :tls },
        on_api_key_change: -> { reloads << :api_key },
        logger: CredentialRefresherSpecSupport::RecordingLogger.new
      ).start

      File.write(cert_path, "second")
      File.write(token_path, "second")
      refresher.refresh_changed_sources

      assert_equal %i[tls api_key], reloads
    ensure
      refresher.stop
    end
  end
end
