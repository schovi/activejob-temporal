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

      # Configures the gem with a block and validates after mutation.
      #
      # @yield [config] Gives the configuration object to the block
      # @yieldparam config [Configuration] the configuration to modify
      # @return [Configuration] the configuration object
      # @raise [ConfigurationError] if validation fails after configuration
      def configure
        return config unless block_given?

        @config_mvar ||= Concurrent::MVar.new(Configuration.new)
        @config_mvar.borrow do |configuration|
          configuration.in_configure_block = true

          begin
            yield(configuration)
          ensure
            configuration.in_configure_block = false
          end
        end

        validate!
      end

      # Validates the current configuration.
      #
      # @return [void]
      # @raise [ConfigurationError] if validation fails
      def validate!
        validator = build_validator
        raise ConfigurationError, Configuration.format_validation_errors(validator.errors) unless validator.valid?
      end

      private

      def build_validator
        validator = ConfigValidator.new

        CONFIGURATION_ATTRIBUTES.each_key do |attribute|
          validator.public_send("#{attribute}=", config.public_send(attribute))
        end

        validator
      end
    end
  end
end
