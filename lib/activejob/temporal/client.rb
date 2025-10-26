# frozen_string_literal: true

begin
  require "temporalio/client"
rescue LoadError
  # The Temporal Ruby SDK is not present in development/test by default.
  # Tests stub Temporalio::Client, and production users must include the SDK.
end

module ActiveJob
  module Temporal
    module Client
      TLS_CERT_ENV = "TEMPORAL_TLS_CERT"
      TLS_KEY_ENV = "TEMPORAL_TLS_KEY"
      TLS_SERVER_NAME_ENV = "TEMPORAL_TLS_SERVER_NAME"

      module_function

      def build(configuration)
        Temporalio::Client.connect(**connection_options(configuration))
      rescue StandardError => e
        raise ActiveJob::Temporal::Error,
              format(
                "Unable to connect to Temporal at %<target>s (namespace: %<namespace>s): %<error>s",
                target: configuration.target,
                namespace: configuration.namespace,
                error: e.message
              )
      end

      def connection_options(configuration)
        options = {
          target: configuration.target,
          namespace: configuration.namespace
        }

        tls = tls_options(configuration)
        options[:tls] = tls if tls
        options
      end
      private_class_method :connection_options

      def tls_options(configuration)
        return configuration.tls if configuration.respond_to?(:tls) && configuration.tls

        cert = ENV.fetch(TLS_CERT_ENV, nil)
        key = ENV.fetch(TLS_KEY_ENV, nil)
        server_name = ENV.fetch(TLS_SERVER_NAME_ENV, nil)
        return nil unless cert || key || server_name

        {
          certificate: cert,
          private_key: key,
          server_name: server_name
        }.compact
      end
      private_class_method :tls_options
    end
  end
end
