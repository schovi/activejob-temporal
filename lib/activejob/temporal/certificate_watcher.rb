# frozen_string_literal: true

require_relative "listen_warning_filter"

module ActiveJob
  module Temporal
    # Watches TLS certificate files and runs a reload callback when they change.
    class CertificateWatcher
      DEFAULT_DEBOUNCE_SECONDS = 1.0

      def self.paths_from_config(configuration)
        [
          configuration.tls_cert_path,
          configuration.tls_key_path,
          configuration.tls_server_root_ca_cert_path
        ].compact.reject { |path| path.to_s.strip.empty? }
      end

      def initialize(paths:, reload_callback:, listener_factory: nil, debounce_seconds: DEFAULT_DEBOUNCE_SECONDS)
        @paths = paths.map { |path| File.expand_path(path) }.uniq
        @reload_callback = reload_callback
        @listener_factory = listener_factory
        @debounce_seconds = debounce_seconds
        @mutex = Mutex.new
        @last_reload_at = nil
        @listener = nil
        @trailing_reload = nil
      end

      def start
        return self if @paths.empty? || @listener

        @listener = listener_factory.to(*directories) do |modified, added, removed|
          handle_changes(modified + added + removed)
        end
        @listener.start
        self
      end

      def stop
        @listener&.stop
        @listener = nil
        @mutex.synchronize { @trailing_reload }&.kill
      end

      def handle_changes(changed_paths)
        return unless relevant_change?(changed_paths)

        if debounced?
          schedule_trailing_reload
        else
          reload(retry_on_failure: true)
        end
      end

      private

      # A failed reload clears the debounce stamp so the next change reloads
      # immediately, and gets one retry in case no further change arrives.
      def reload(retry_on_failure:)
        @reload_callback.call
      rescue StandardError
        @mutex.synchronize { @last_reload_at = nil }
        schedule_trailing_reload if retry_on_failure
      end

      # Cert and key rotate as separate writes, so the second one lands inside
      # the debounce window. Flush it once the window closes instead of dropping it.
      def schedule_trailing_reload
        @mutex.synchronize do
          return if @trailing_reload&.alive?

          @trailing_reload = Thread.new do
            sleep(@debounce_seconds)
            @mutex.synchronize { @last_reload_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            reload(retry_on_failure: false)
          end
        end
      end

      def directories
        @directories ||= @paths.map { |path| File.dirname(path) }.uniq
      end

      def listener_factory
        @listener_factory ||= begin
          require "listen"
          ListenWarningFilter.install!
          Listen
        rescue LoadError => e
          raise LoadError, "listen gem is required when tls_cert_watch is enabled: #{e.message}"
        end
      end

      # Kubernetes projected and secret volumes rotate atomically: kubelet writes a new timestamped
      # directory and swaps a `..data` symlink, so the watched file's own path never appears in the
      # change events. Any change inside a watched file's directory therefore counts as relevant;
      # the debounce absorbs the multi-event burst a rotation produces.
      def relevant_change?(changed_paths)
        changed_paths.any? do |path|
          expanded = File.expand_path(path)
          @paths.include?(expanded) || directories.any? { |dir| expanded.start_with?("#{dir}/") }
        end
      end

      def debounced?
        return false unless @debounce_seconds.positive?

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @mutex.synchronize do
          return true if @last_reload_at && (now - @last_reload_at) < @debounce_seconds

          @last_reload_at = now
          false
        end
      end
    end
  end
end
