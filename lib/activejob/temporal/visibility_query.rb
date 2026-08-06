# frozen_string_literal: true

module ActiveJob
  module Temporal
    module VisibilityQuery
      SAFE_VALUE_PATTERN = /\A[A-Za-z0-9_.:-]+\z/

      module_function

      # Quotes a value for use in a Temporal visibility list filter.
      #
      # Escaping alone is not enough: Temporal's list filter grammar also treats
      # backslashes as escapes, so a value containing one can break out of the
      # quoted literal. Values are restricted to an allowlist instead.
      #
      # @param value [#to_s] Value to embed in a list filter
      # @return [String] Single-quoted literal
      # @raise [ArgumentError] if the value contains characters outside the allowlist
      def quote(value)
        string_value = value.to_s
        return "'#{string_value}'" if string_value.match?(SAFE_VALUE_PATTERN)

        raise ArgumentError,
              "visibility query values may only contain letters, numbers, underscore, hyphen, period, and colon"
      end
    end
  end
end
