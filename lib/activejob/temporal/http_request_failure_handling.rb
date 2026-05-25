# frozen_string_literal: true

module ActiveJob
  module Temporal
    module HttpRequestFailureHandling
      private

      def serve_client(client)
        handle_client(client)
      rescue IOError, SystemCallError
        nil
      rescue StandardError => e
        log_request_failure(e)
        write_failure_response(client)
      ensure
        client&.close
      end

      def write_failure_response(client)
        case self.class::REQUEST_FAILURE_FORMAT
        when :json
          write_json(client, 500, { error: "internal_server_error" })
        when :text
          write_text(client, 500, "internal_server_error\n")
        end
      rescue IOError, SystemCallError
        nil
      end

      def log_request_failure(error)
        ActiveJob::Temporal::Logger.error(
          self.class::REQUEST_FAILURE_EVENT,
          error_class: error.class.name,
          message: error.message.to_s
        )
      rescue StandardError
        nil
      end
    end
  end
end
