# frozen_string_literal: true

require "active_job"
require "active_support/concern"

module ActiveJob
  module Temporal
    module SignalQueryOptions
      extend ActiveSupport::Concern

      HANDLER_NAME_PATTERN = /\A[a-zA-Z_]\w*\z/
      BUILT_IN_SIGNAL_NAMES = %w[pause resume].freeze
      BUILT_IN_QUERY_NAMES = %w[pause_reason paused phase signals state].freeze
      BUILT_IN_UPDATE_NAMES = [].freeze

      module ClassMethods
        def temporal_signal(name, &block)
          handler_name = normalize_handler_name(name)
          validate_custom_handler_name!(handler_name, "signal", BUILT_IN_SIGNAL_NAMES)
          local_temporal_signal_handlers[handler_name] = block || default_signal_handler(handler_name)
        end

        def temporal_query(name, &block)
          raise ArgumentError, "temporal_query requires a block" unless block

          handler_name = normalize_handler_name(name)
          validate_custom_handler_name!(handler_name, "query", BUILT_IN_QUERY_NAMES)
          local_temporal_query_handlers[handler_name] = block
        end

        def temporal_update(name, &block)
          raise ArgumentError, "temporal_update requires a block" unless block

          handler_name = normalize_handler_name(name)
          validate_custom_handler_name!(handler_name, "update", BUILT_IN_UPDATE_NAMES)
          local_temporal_update_handlers[handler_name] = block
        end

        def temporal_signal_handlers
          inherited_temporal_handlers(:temporal_signal_handlers).merge(local_temporal_signal_handlers)
        end

        def temporal_query_handlers
          inherited_temporal_handlers(:temporal_query_handlers).merge(local_temporal_query_handlers)
        end

        def temporal_update_handlers
          inherited_temporal_handlers(:temporal_update_handlers).merge(local_temporal_update_handlers)
        end

        def temporal_signal_handler_names
          temporal_signal_handlers.keys
        end

        def temporal_query_handler_names
          temporal_query_handlers.keys
        end

        def temporal_update_handler_names
          temporal_update_handlers.keys
        end

        private

        def local_temporal_signal_handlers
          @local_temporal_signal_handlers ||= {}
        end

        def local_temporal_query_handlers
          @local_temporal_query_handlers ||= {}
        end

        def local_temporal_update_handlers
          @local_temporal_update_handlers ||= {}
        end

        def normalize_handler_name(name)
          handler_name = name.to_s
          return handler_name if handler_name.match?(HANDLER_NAME_PATTERN)

          raise ArgumentError, "signal and query names must start with a letter or underscore and contain word chars"
        end

        def validate_custom_handler_name!(handler_name, handler_type, built_in_names)
          return unless built_in_names.include?(handler_name)

          raise ArgumentError, "#{handler_type} name #{handler_name.inspect} is reserved by ActiveJob::Temporal"
        end

        def inherited_temporal_handlers(method_name)
          return {} unless superclass.respond_to?(method_name)

          superclass.public_send(method_name)
        end

        def default_signal_handler(handler_name)
          lambda do |state, *args|
            state[handler_name] = args.length == 1 ? args.first : args
          end
        end
      end
    end
  end
end

ActiveJob::Base.include(ActiveJob::Temporal::SignalQueryOptions) if defined?(ActiveJob::Base)
