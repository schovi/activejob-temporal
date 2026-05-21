# frozen_string_literal: true

require "listen"

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

      def initialize(paths:, reload_callback:, listener_factory: Listen, debounce_seconds: DEFAULT_DEBOUNCE_SECONDS)
        @paths = paths.map { |path| File.expand_path(path) }.uniq
        @reload_callback = reload_callback
        @listener_factory = listener_factory
        @debounce_seconds = debounce_seconds
        @mutex = Mutex.new
        @last_reload_at = nil
        @listener = nil
      end

      def start
        return self if @paths.empty? || @listener

        @listener = @listener_factory.to(*directories) do |modified, added, removed|
          handle_changes(modified + added + removed)
        end
        @listener.start
        self
      end

      def stop
        @listener&.stop
        @listener = nil
      end

      def handle_changes(changed_paths)
        return unless relevant_change?(changed_paths)
        return if debounced?

        @reload_callback.call
      end

      private

      def directories
        @directories ||= @paths.map { |path| File.dirname(path) }.uniq
      end

      def relevant_change?(changed_paths)
        changed_paths.any? do |path|
          @paths.include?(File.expand_path(path))
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
