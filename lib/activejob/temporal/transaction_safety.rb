# frozen_string_literal: true

require "active_support/lazy_load_hooks"

module ActiveJob
  module Temporal
    module TransactionSafety
      module QueueAdapterSetter
        def queue_adapter=(adapter)
          super.tap do
            self.enqueue_after_transaction_commit = true if temporal_queue_adapter?(adapter)
          end
        end

        private

        def temporal_queue_adapter?(adapter)
          case adapter
          when Symbol, String
            adapter.to_s == "temporal"
          else
            defined?(ActiveJob::QueueAdapters::TemporalAdapter) &&
              adapter.is_a?(ActiveJob::QueueAdapters::TemporalAdapter)
          end
        end
      end

      module_function

      def install!
        ActiveSupport.on_load(:active_job) do
          singleton_class.prepend(QueueAdapterSetter) unless singleton_class < QueueAdapterSetter
        end
      end
    end
  end
end

ActiveJob::Temporal::TransactionSafety.install!
