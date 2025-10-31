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
    # @note TLS Configuration Precedence
    #   If both `config.tls` and environment variables are present, `config.tls` takes
    #   precedence. Environment variables are only used if `config.tls` is nil.
    #
    # @note Environment Variables
    #   - TEMPORAL_TLS_CERT: TLS certificate (PEM format, full content)
    #   - TEMPORAL_TLS_KEY: TLS private key (PEM format, full content)
    #   - TEMPORAL_TLS_SERVER_NAME: TLS server name for verification
    #
    # @example Basic connection
    #   config = ActiveJob::Temporal.config
    #   client = Client.build(config)
    #
    # @example TLS via environment variables
    #   ENV["TEMPORAL_TLS_CERT"] = File.read("cert.pem")
    #   ENV["TEMPORAL_TLS_KEY"] = File.read("key.pem")
    #   ENV["TEMPORAL_TLS_SERVER_NAME"] = "temporal.example.com"
    #   client = Client.build(config)
    #
    # @example TLS via configuration object
    #   ActiveJob::Temporal.configure do |config|
    #     config.tls = {
    #       certificate: File.read("cert.pem"),
    #       private_key: File.read("key.pem"),
    #       server_name: "temporal.example.com"
    #     }
    #   end
    #   client = ActiveJob::Temporal.client
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
      # @raise [OpenSSL::SSL::SSLError] if TLS certificate validation fails
      # @raise [OpenSSL::PKey::RSAError] if TLS private key is invalid
      # @raise [OpenSSL::X509::CertificateError] if TLS certificate is malformed
      # @raise [SocketError] if target hostname cannot be resolved
      # @raise [Errno::ECONNREFUSED] if target port is not accepting connections
      # @raise [Errno::ETIMEDOUT] if connection times out
      #
      # @example Basic usage
      #   config = ActiveJob::Temporal::Configuration.new
      #   config.target = "temporal.example.com:7233"
      #   config.namespace = "production"
      #   client = Client.build(config)
      #
      # @example With TLS via environment variables
      #   ENV["TEMPORAL_TLS_CERT"] = File.read("client.pem")
      #   ENV["TEMPORAL_TLS_KEY"] = File.read("client-key.pem")
      #   ENV["TEMPORAL_TLS_SERVER_NAME"] = "temporal.prod.example.com"
      #   client = Client.build(config)
      #   # Client will connect using mutual TLS
      #
      # @example Handling connection failures
      #   begin
      #     client = Client.build(config)
      #   rescue ActiveJob::Temporal::Error => e
      #     Rails.logger.fatal("Cannot connect to Temporal: #{e.message}")
      #     # Fall back to different adapter or alert operations team
      #   end
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

      # Builds connection keyword arguments (including TLS options).
      # @api private
      def connection_kwargs(configuration)
        tls = tls_options(configuration)
        return {} unless tls

        { tls: tls }
      end
      private_class_method :connection_kwargs

      # Extracts TLS options from config or environment variables.
      # @api private
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
