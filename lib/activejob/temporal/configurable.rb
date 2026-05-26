# frozen_string_literal: true

require "concurrent/mvar"

require_relative "configuration"

module ActiveJob
  module Temporal
    # Module-level configuration API for ActiveJob::Temporal.
    #
    # @api private
    module Configurable
      # Returns the global configuration object.
      #
      # @return [Configuration] the gem configuration
      def config
        @config_mvar ||= Concurrent::MVar.new(Configuration.new)
        @config_mvar.value
      end
      alias configuration config

      # Configures the gem with a block and validates before publishing changes.
      #
      # @yield [config] Gives the configuration object to the block
      # @yieldparam config [Configuration] the configuration to modify
      # @return [Configuration] the configuration object
      # @raise [ConfigurationError] if validation fails after configuration
      def configure(&block)
        return config unless block

        @config_mvar ||= Concurrent::MVar.new(Configuration.new)
        applied_configuration = nil

        @config_mvar.modify do |current_configuration|
          applied_configuration = build_configuration_candidate(current_configuration, &block)
        end

        applied_configuration
      end

      # Validates the current configuration.
      #
      # @return [void]
      # @raise [ConfigurationError] if validation fails
      def validate!
        config.validate!
      end

      private

      def build_configuration_candidate(current_configuration)
        candidate_configuration = current_configuration.dup
        begin
          candidate_configuration.in_configure_block = true
          yield(candidate_configuration)
        ensure
          candidate_configuration.in_configure_block = false
        end

        candidate_configuration.validate!
        deactivate_replaced_observability_adapters(current_configuration, candidate_configuration)
        publish_configuration_candidate(current_configuration, candidate_configuration)
      rescue StandardError
        discard_configuration_candidate(current_configuration, candidate_configuration)
        raise
      end

      def publish_configuration_candidate(current_configuration, candidate_configuration)
        current_configuration.instance_variable_set(
          :@attributes,
          candidate_configuration.instance_variable_get(:@attributes)
        )
        current_configuration.in_configure_block = false
        current_configuration.finalize_configuration_copy!
      end

      def deactivate_replaced_observability_adapters(previous_configuration, current_configuration)
        previous_adapters = previous_configuration.observability.adapters
        current_adapters = current_configuration.observability.adapters

        previous_adapters.each do |adapter|
          adapter.stop! unless current_adapters.include?(adapter)
        end
      end

      def discard_configuration_candidate(previous_configuration, candidate_configuration)
        previous_adapters = previous_configuration.observability.adapters
        candidate_adapters = candidate_configuration.observability.adapters

        candidate_adapters.each do |adapter|
          adapter.stop! unless previous_adapters.include?(adapter)
        end
      rescue StandardError
        nil
      end
    end
  end
end
