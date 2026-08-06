# frozen_string_literal: true

module ActiveJob
  module Temporal
    # Silences listen's "directory is already being watched!" warning for Kubernetes
    # secret and projected volumes.
    #
    # kubelet's atomic writer keeps a `..data` symlink pointing at the current
    # `..<timestamp>` payload directory, so the same real directory is reachable twice
    # and listen's symlink detector flags every such volume on boot. The condition is
    # expected and harmless there - listen skips the duplicate subtree and change events
    # still reach the watcher - but the message goes out through Kernel#warn and lands
    # in pod logs at error severity. Only that case is silenced: the message must name
    # a `..`-prefixed path component, the atomic writer's signature. Every other message
    # keeps the previously configured behavior, and listen's own
    # LISTEN_GEM_ADAPTER_WARN_BEHAVIOR environment variable still overrides everything.
    #
    # @api private
    module ListenWarningFilter
      DUPLICATE_WATCH_MESSAGE = "directory is already being watched"
      ATOMIC_WRITER_PATH_COMPONENT = %r{/\.\.[^/\s]}

      @install_mutex = Mutex.new
      @installed = false

      class << self
        # Idempotent; expects the listen gem to be loaded.
        def install!
          @install_mutex.synchronize do
            return if @installed

            previous = Listen.adapter_warn_behavior
            Listen.adapter_warn_behavior = lambda do |message|
              next :silent if atomic_writer_duplicate?(message)

              previous.respond_to?(:call) ? previous.call(message) : previous
            end
            @installed = true
          end
        end

        private

        def atomic_writer_duplicate?(message)
          text = message.to_s
          text.include?(DUPLICATE_WATCH_MESSAGE) && text.match?(ATOMIC_WRITER_PATH_COMPONENT)
        end
      end
    end
  end
end
