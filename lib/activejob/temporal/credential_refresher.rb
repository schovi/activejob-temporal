# frozen_string_literal: true

require "digest"
require_relative "../temporal"

module ActiveJob
  module Temporal
    # Keeps credential files fresh in a long-lived process: TLS material, API key files, or
    # anything else read once at boot and rotated underneath the process later.
    #
    # Change detection is a content digest compared on an interval, so the only thing that can fire
    # a callback is the bytes behind a path actually differing. Filesystem events (see :file_events)
    # are an optional accelerator that wakes the loop early; they never decide whether a reload
    # happens, so a missing `listen` gem or a mount without working inotify costs latency, not
    # correctness.
    #
    # @example Worker: rebuild the client on cert rotation, patch the live connection on token rotation
    #   refresher = CredentialRefresher.from_config(
    #     ActiveJob::Temporal.config,
    #     on_tls_change: -> { client_reloader.reload(source: "credential_refresh") }
    #   ).start
    #
    # @example Enqueue-side process (web, Sidekiq) with a rotating projected token
    #   require "activejob/temporal/credential_refresher"
    #   ActiveJob::Temporal::CredentialRefresher.from_config(ActiveJob::Temporal.config).start
    class CredentialRefresher
      # kubelet keeps the live secret in a timestamped sibling of `..data`, so listen's recursive
      # scan reaches the same real directory twice and prints a SymlinkLoop error to stderr.
      # Getting this wrong costs that stderr noise and nothing else: listen only ever nudges the
      # loop, so the digest still decides, and the interval still backs it up.
      #
      # @api private
      KUBERNETES_VERSIONED_DIR = /\A\.\.\d/
      private_constant :KUBERNETES_VERSIONED_DIR

      DEFAULT_POLL_INTERVAL = 30

      # Files digested as one unit. Cert and key rotate as separate writes, so grouping them turns
      # a rotation into a single callback instead of a pair.
      Source = Struct.new(:name, :paths, :on_change, keyword_init: true)

      class << self
        # Builds a refresher from the `tls_cert_watch` / `api_key_watch` configuration flags.
        # The callbacks default to the process-wide reload paths, which is what an enqueue-side
        # process wants; workers override the TLS one so the running worker gets the new client.
        #
        # @param configuration [Configuration] the gem configuration
        # @param on_tls_change [#call] invoked when any TLS file changes
        # @param on_api_key_change [#call] invoked when the API key file changes
        # @param logger [#log_event, #warn, #error] structured logger
        # @param listener_factory [#to, nil] injection point for tests, defaults to `Listen`
        # @return [CredentialRefresher] a refresher with no sources when both flags are off
        def from_config(configuration,
                        on_tls_change: -> { ActiveJob::Temporal.reload_client! },
                        on_api_key_change: -> { ActiveJob::Temporal.refresh_api_key! },
                        logger: ActiveJob::Temporal::Logger,
                        listener_factory: nil)
          sources = []

          if configuration.tls_cert_watch
            sources << Source.new(name: "tls", paths: tls_paths(configuration), on_change: on_tls_change)
          end

          if configuration.api_key_watch
            sources << Source.new(name: "api_key", paths: [configuration.api_key_file], on_change: on_api_key_change)
          end

          new(
            sources: sources,
            poll_interval: configuration.credential_poll_interval,
            file_events: configuration.credential_file_events,
            logger: logger,
            listener_factory: listener_factory
          )
        end

        # @param configuration [Configuration] the gem configuration
        # @return [Array<String>] configured TLS file paths, blanks removed
        def tls_paths(configuration)
          [
            configuration.tls_cert_path,
            configuration.tls_key_path,
            configuration.tls_server_root_ca_cert_path
          ].compact.reject { |path| path.to_s.strip.empty? }
        end
      end

      # @param sources [Array<Source>] credential groups to keep fresh
      # @param poll_interval [Integer, Float] seconds between digest comparisons
      # @param file_events [Boolean] wake the loop early on filesystem events, requires `listen`
      # @param logger [#log_event, #warn, #error] structured logger
      # @param listener_factory [#to, nil] injection point for tests, defaults to `Listen`
      def initialize(sources:, poll_interval: DEFAULT_POLL_INTERVAL, file_events: false,
                     logger: ActiveJob::Temporal::Logger, listener_factory: nil)
        @sources = sources.reject { |source| source.paths.compact.empty? }
        @poll_interval = poll_interval
        @file_events = file_events
        @logger = logger
        @listener_factory = listener_factory
        @wakeups = Thread::Queue.new
        @digests = {}
        @thread = nil
        @listener = nil
      end

      # Baselines each digest before polling, so a process booting on an already-rotated file does
      # not fire a redundant reload on its first check.
      #
      # @return [self]
      def start
        return self if @sources.empty? || @thread

        @sources.each { |source| @digests[source.name] = digest(source) }
        @thread = Thread.new { run }
        start_listener if @file_events
        self
      end

      # @return [void]
      def stop
        @listener&.stop
        @listener = nil
        @wakeups.close
        @thread&.join
        @thread = nil
      end

      # Re-reads every source and fires the callbacks whose content changed. Safe to call at any
      # rate: unchanged content is a no-op.
      #
      # @return [void]
      def refresh_changed_sources
        @sources.each { |source| refresh(source) }
      end

      # Wakes the poll loop so the next comparison happens now instead of on the next tick.
      # Decides nothing on its own.
      #
      # @return [void]
      def nudge
        @wakeups << :wakeup
      rescue ClosedQueueError
        nil
      end

      private

      def run
        until @wakeups.closed?
          @wakeups.pop(timeout: @poll_interval)
          break if @wakeups.closed?

          # A rotation emits a burst of events; collapse them into the single check that follows.
          @wakeups.clear
          refresh_changed_sources
        end
      end

      def refresh(source)
        current = digest(source)
        return if current.nil? || current == @digests[source.name]

        source.on_change.call
        # Stamped only after the callback succeeds, so a failed reload is retried on the next tick.
        @digests[source.name] = current
        @logger.log_event("credential_refreshed", source: source.name)
      rescue StandardError => e
        @logger.error(
          "credential_refresh_failed",
          source: source.name,
          error_class: e.class.name,
          message: e.message
        )
      end

      # A path can be briefly unreadable while kubelet swaps the mount. Treat that as "no reading"
      # so the next tick retries, rather than reloading against a half-written credential.
      def digest(source)
        contents = source.paths.compact.map { |path| TLSFile.read(path) }
        Digest::SHA256.hexdigest(contents.join("\0"))
      rescue TLSFile::Error
        nil
      end

      def start_listener
        @listener = listener_factory.to(*watched_directories, ignore: KUBERNETES_VERSIONED_DIR) { nudge }
        @listener.start
      rescue LoadError => e
        # Polling already guarantees the refresh, so a missing listen gem is a latency
        # regression rather than a boot failure.
        @logger.warn(
          "credential_file_events_unavailable",
          error_class: e.class.name,
          message: e.message,
          poll_interval_seconds: @poll_interval
        )
      end

      def watched_directories
        @sources.flat_map(&:paths).compact.map { |path| File.dirname(File.expand_path(path)) }.uniq
      end

      def listener_factory
        @listener_factory ||= begin
          require "listen"
          Listen
        end
      end
    end
  end
end
