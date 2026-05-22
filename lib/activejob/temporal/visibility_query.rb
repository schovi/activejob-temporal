# frozen_string_literal: true

module ActiveJob
  module Temporal
    module VisibilityQuery
      module_function

      def quote(value)
        "'#{value.to_s.gsub("'", "''")}'"
      end
    end
  end
end
