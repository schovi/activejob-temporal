# frozen_string_literal: true

begin
  require "temporalio/client"
rescue LoadError
  # The Temporal Ruby SDK is not present in development/test by default.
  # Tests stub Temporalio::Client, and production users must include the SDK.
end

module ActiveJob
  module Temporal
    # Builds Temporal client connections.
    #
    # This module encapsulates the logic for connecting to a Temporal cluster
    # with optional TLS configuration. TLS options can be provided via configuration
    # attributes or environment variables.
    #
    # @note Environment Variables
    #   - TEMPORAL_TLS_CERT: TLS certificate (PEM format)
    #   - TEMPORAL_TLS_KEY: TLS private key (PEM format)
    #   - TEMPORAL_TLS_SERVER_NAME: TLS server name for verification
    #
    # @example Basic connection
    #   config = ActiveJob::Temporal.config
    #   client = Client.build(config)
    #
    # @example TLS via environment variables
    #   ENV["TEMPORAL_TLS_CERT"] = File.read("cert.pem")
    #   ENV["TEMPORAL_TLS_KEY"] = File.read("key.pem")
    #   client = Client.build(config)
    module Client
      # Environment variable name for TLS certificate
      TLS_CERT_ENV = "TEMPORAL_TLS_CERT"
      # Environment variable name for TLS private key
      TLS_KEY_ENV = "TEMPORAL_TLS_KEY"
      # Environment variable name for TLS server name
      TLS_SERVER_NAME_ENV = "TEMPORAL_TLS_SERVER_NAME"

      module_function

      # Builds and connects a Temporal client.
      #
      # Creates a new Temporalio::Client instance connected to the configured
      # Temporal cluster. TLS options are automatically included if present in
      # configuration or environment variables.
      #
      # @param configuration [Configuration] Gem configuration object with target/namespace
      #
      # @return [Temporalio::Client] Connected Temporal client
      #
      # @raise [ActiveJob::Temporal::Error] if connection fails (includes target, namespace, and error message)
      #
      # @example Basic usage
      #   config = ActiveJob::Temporal::Configuration.new
      #   config.target = "temporal.example.com:7233"
      #   config.namespace = "production"
      #   client = Client.build(config)
      def build(configuration)
        Temporalio::Client.connect(
          configuration.target,
          configuration.namespace,
          **connection_kwargs(configuration)
        )
      rescue StandardError => e
        raise ActiveJob::Temporal::Error,
              format(
                "Unable to connect to Temporal at %<target>s (namespace: %<namespace>s): %<error>s",
                target: configuration.target,
                namespace: configuration.namespace,
                error: e.message
              )
      end

      def connection_kwargs(configuration)
        tls = tls_options(configuration)
        return {} unless tls

        { tls: tls }
      end
      private_class_method :connection_kwargs

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
