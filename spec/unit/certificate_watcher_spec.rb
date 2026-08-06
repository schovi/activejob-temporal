# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "activejob/temporal/certificate_watcher"

module CertificateWatcherSpecSupport
  FakeListener = Struct.new(:directories, :callback, :started, :stopped) do
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

    def to(*directories, &callback)
      @listener = FakeListener.new(directories, callback, false, false)
    end
  end
end

describe ActiveJob::Temporal::CertificateWatcher do
  it "extracts configured TLS paths" do
    config_class = Struct.new(:tls_cert_path, :tls_key_path, :tls_server_root_ca_cert_path)
    config = config_class.new("/cert.pem", "/key.pem", nil)

    assert_equal ["/cert.pem", "/key.pem"], described_class.paths_from_config(config)
  end

  it "watches parent directories and reloads when a watched file changes" do
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, "client.pem")
      key_path = File.join(directory, "client-key.pem")
      reloads = []
      listener_factory = CertificateWatcherSpecSupport::ListenerFactory.new

      watcher = described_class.new(
        paths: [cert_path, key_path],
        reload_callback: -> { reloads << :reload },
        listener_factory: listener_factory,
        debounce_seconds: 0
      )

      assert_same watcher, watcher.start
      assert listener_factory.listener.started
      assert_equal [directory], listener_factory.listener.directories

      listener_factory.listener.callback.call([cert_path], [], [])

      assert_equal [:reload], reloads
    end
  end

  it "ignores unrelated file changes" do
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, "client.pem")
      reloads = []
      watcher = described_class.new(
        paths: [cert_path],
        reload_callback: -> { reloads << :reload },
        listener_factory: CertificateWatcherSpecSupport::ListenerFactory.new,
        debounce_seconds: 0
      )

      watcher.handle_changes([File.join(directory, "other.pem")])

      assert_empty reloads
    end
  end

  it "debounces duplicate file change events" do
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, "client.pem")
      reloads = []
      watcher = described_class.new(
        paths: [cert_path],
        reload_callback: -> { reloads << :reload },
        listener_factory: CertificateWatcherSpecSupport::ListenerFactory.new,
        debounce_seconds: 60
      )

      watcher.handle_changes([cert_path])
      watcher.handle_changes([cert_path])

      assert_equal [:reload], reloads
    end
  end

  it "reloads again for the second file of a cert and key rotation pair" do
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, "client.pem")
      key_path = File.join(directory, "client-key.pem")
      reloads = Queue.new
      watcher = described_class.new(
        paths: [cert_path, key_path],
        reload_callback: -> { reloads << :reload },
        listener_factory: CertificateWatcherSpecSupport::ListenerFactory.new,
        debounce_seconds: 0.05
      )

      watcher.handle_changes([cert_path])
      watcher.handle_changes([key_path])

      assert_equal 1, reloads.size
      assert_equal :reload, reloads.pop(timeout: 5)
      assert_equal :reload, reloads.pop(timeout: 5)
    ensure
      watcher.stop
    end
  end

  it "retries a failed reload" do
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, "client.pem")
      attempts = Queue.new
      failed = false
      watcher = described_class.new(
        paths: [cert_path],
        reload_callback: lambda {
          attempts << :attempt
          next if failed

          failed = true
          raise "reload failed"
        },
        listener_factory: CertificateWatcherSpecSupport::ListenerFactory.new,
        debounce_seconds: 0.05
      )

      watcher.handle_changes([cert_path])

      assert_equal :attempt, attempts.pop(timeout: 5)
      assert_equal :attempt, attempts.pop(timeout: 5)
    ensure
      watcher.stop
    end
  end

  it "stops the listener" do
    Dir.mktmpdir do |directory|
      cert_path = File.join(directory, "client.pem")
      listener_factory = CertificateWatcherSpecSupport::ListenerFactory.new
      watcher = described_class.new(
        paths: [cert_path],
        reload_callback: -> {},
        listener_factory: listener_factory
      )

      watcher.start
      watcher.stop

      assert listener_factory.listener.stopped
    end
  end
end
