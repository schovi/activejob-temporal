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

RSpec.describe ActiveJob::Temporal::CertificateWatcher do
  it "extracts configured TLS paths" do
    config = instance_double(
      ActiveJob::Temporal::Configuration,
      tls_cert_path: "/cert.pem",
      tls_key_path: "/key.pem",
      tls_server_root_ca_cert_path: nil
    )

    expect(described_class.paths_from_config(config)).to eq(["/cert.pem", "/key.pem"])
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

      expect(watcher.start).to be(watcher)
      expect(listener_factory.listener.started).to be(true)
      expect(listener_factory.listener.directories).to eq([directory])

      listener_factory.listener.callback.call([cert_path], [], [])

      expect(reloads).to eq([:reload])
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

      expect(reloads).to be_empty
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

      expect(reloads).to eq([:reload])
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

      expect(listener_factory.listener.stopped).to be(true)
    end
  end
end
