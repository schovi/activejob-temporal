# frozen_string_literal: true

require "active_job"

module ActiveJob
  module Temporal
    # Provides per-job timeout configuration via the +temporal_options+ class method.
    #
    # @example Basic timeout override
    #   class QuickJob < ApplicationJob
    #     temporal_options start_to_close_timeout: 30.seconds
    #   end
    #
    # @example Long-running job with heartbeat
    #   class DataProcessingJob < ApplicationJob
    #     temporal_options(
    #       start_to_close_timeout: 2.hours,
    #       heartbeat_timeout: 30.seconds
    #     )
    #   end
    #
    # @example All timeout types configured
    #   class CriticalJob < ApplicationJob
    #     temporal_options(
    #       start_to_close_timeout: 10.minutes,
    #       schedule_to_start_timeout: 1.minute,
    #       schedule_to_close_timeout: 15.minutes,
    #       heartbeat_timeout: 10.seconds
    #     )
    #   end
    module TemporalOptions
      extend ActiveSupport::Concern

      VALID_TIMEOUT_KEYS = %i[
        start_to_close_timeout
        schedule_to_close_timeout
        schedule_to_start_timeout
        heartbeat_timeout
      ].freeze

      class_methods do
        # Define Temporal activity timeout options for this job class.
        #
        # @param options [Hash] Timeout configuration options
        # @option options [Integer, ActiveSupport::Duration] :start_to_close_timeout
        #   Maximum execution time for a single activity attempt
        # @option options [Integer, ActiveSupport::Duration] :schedule_to_close_timeout
        #   Total time including all retries from schedule to completion
        # @option options [Integer, ActiveSupport::Duration] :schedule_to_start_timeout
        #   Maximum wait time before activity starts after scheduling
        # @option options [Integer, ActiveSupport::Duration] :heartbeat_timeout
        #   Maximum interval between heartbeats before activity is considered failed
        #
        # @return [Hash] The stored timeout options (when called without arguments)
        #
        # @note At least one of +start_to_close_timeout+ or +schedule_to_close_timeout+
        #   must be specified. Temporal SDK will validate this requirement.
        #
        # @note Timeout values can be specified as either integers (seconds) or
        #   ActiveSupport::Duration objects (e.g., 2.hours, 30.seconds)
        def temporal_options(options = nil)
          if options
            validate_timeout_keys!(options)
            @temporal_options = normalize_timeout_values(options)
          end
          @temporal_options || {}
        end

        private

        # Validates that only recognized timeout keys are provided
        #
        # @param options [Hash] The options hash to validate
        # @raise [ArgumentError] If invalid keys are present
        # @api private
        def validate_timeout_keys!(options)
          invalid_keys = options.keys - VALID_TIMEOUT_KEYS
          return if invalid_keys.empty?

          raise ArgumentError,
                "Invalid temporal_options keys: #{invalid_keys.join(', ')}. " \
                "Valid keys are: #{VALID_TIMEOUT_KEYS.join(', ')}"
        end

        # Normalizes timeout values to numeric seconds
        #
        # Converts ActiveSupport::Duration objects to their numeric second values
        # while preserving integer/float values as-is.
        #
        # @param options [Hash] Raw timeout options with mixed value types
        # @return [Hash] Normalized options with all values as numbers
        # @api private
        def normalize_timeout_values(options)
          options.transform_values do |value|
            case value
            when ActiveSupport::Duration
              value.to_f
            when Numeric
              value
            else
              raise ArgumentError,
                    "Timeout values must be numeric or ActiveSupport::Duration, got: #{value.class}"
            end
          end
        end
      end
    end
  end
end

# Automatically include TemporalOptions into ActiveJob::Base when this file is loaded
ActiveJob::Base.include(ActiveJob::Temporal::TemporalOptions) if defined?(ActiveJob::Base)
