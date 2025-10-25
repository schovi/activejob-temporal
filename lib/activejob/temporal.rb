# frozen_string_literal: true

require_relative "temporal/version"

module ActiveJob
  module Temporal
    class Error < StandardError; end

    # Placeholder configuration struct; expanded in future iterations.
    Configuration = Struct.new(:logger, keyword_init: true)

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        return configuration unless block_given?

        yield(configuration)
      end
    end
  end
end
