# frozen_string_literal: true

require "ipaddr"

module ActiveJob
  module Temporal
    module BindPolicy
      LOOPBACK_HOSTNAMES = %w[localhost].freeze
      TRUE_VALUES = %w[1 true yes on].freeze

      module_function

      def public_bind?(bind_address)
        normalized = bind_address.to_s.strip
        return false if normalized.empty? || LOOPBACK_HOSTNAMES.include?(normalized.downcase)

        !IPAddr.new(normalized).loopback?
      rescue IPAddr::InvalidAddressError
        true
      end

      def allow_public_bind?(value)
        TRUE_VALUES.include?(value.to_s.strip.downcase)
      end

      def validate!(endpoint:, bind_address:, allow_public_bind:, warn_on_allowed: true)
        return unless public_bind?(bind_address)

        unless allow_public_bind
          raise ArgumentError,
                "refusing to expose unauthenticated #{endpoint} endpoint on non-loopback address " \
                "#{bind_address.inspect} without explicit public bind opt-in"
        end

        return unless warn_on_allowed

        warn(
          "Warning: exposing unauthenticated #{endpoint} endpoint on non-loopback address " \
          "#{bind_address.inspect}. Protect it with network policy, a firewall, or an internal-only listener."
        )
      end
    end
  end
end
