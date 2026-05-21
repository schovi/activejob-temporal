# frozen_string_literal: true

module ActiveJob
  module Temporal
    # Rebuilds the Temporal client and swaps it into a running worker.
    class WorkerClientReloader
      def initialize(worker:, logger: ActiveJob::Temporal::Logger, reload_client: ActiveJob::Temporal.method(:reload_client!))
        @worker = worker
        @logger = logger
        @reload_client = reload_client
        @mutex = Mutex.new
      end

      def reload(source:)
        @mutex.synchronize do
          @logger.log_event("certificate_reload_started", source: source)
          new_client = @reload_client.call do |fresh_client|
            @worker.client = fresh_client
          end
          @logger.log_event("certificate_reload_succeeded", source: source)
          new_client
        rescue StandardError => e
          @logger.error(
            "certificate_reload_failed",
            source: source,
            error_class: e.class.name,
            message: e.message
          )
          raise
        end
      end
    end
  end
end
