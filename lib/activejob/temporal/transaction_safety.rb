# frozen_string_literal: true

require "active_support/lazy_load_hooks"

module ActiveJob
  module Temporal
    module TransactionSafety
      module QueueAdapterSetter
        INHERITED_TRANSACTION_SETTING_MISSING = Object.new.freeze

        def queue_adapter=(adapter)
          previous_transaction_setting = enqueue_after_transaction_commit

          super.tap do
            if temporal_queue_adapter?(adapter)
              apply_temporal_transaction_safety(previous_transaction_setting)
            else
              restore_temporal_transaction_safety
            end
          end
        end

        def enqueue_after_transaction_commit=(value)
          super.tap do
            next if setting_temporal_transaction_safety?

            @activejob_temporal_transaction_setting_explicit = true
            @activejob_temporal_transaction_setting_changed_after_safety = true if temporal_transaction_safety_applied?
          end
        end

        private

        def apply_temporal_transaction_safety(previous_transaction_setting)
          return if temporal_transaction_safety_applied?
          return if temporal_transaction_setting_explicit?

          @activejob_temporal_previous_transaction_setting =
            transaction_setting_before_temporal_safety(previous_transaction_setting)
          apply_enqueue_after_transaction_commit_for_temporal(true)
          @activejob_temporal_transaction_safety_applied = true
          @activejob_temporal_transaction_setting_changed_after_safety = false
        end

        def restore_temporal_transaction_safety
          unless temporal_transaction_safety_applied?
            restore_inherited_temporal_transaction_safety
            return
          end

          unless @activejob_temporal_transaction_setting_changed_after_safety
            apply_enqueue_after_transaction_commit_for_temporal(@activejob_temporal_previous_transaction_setting)
          end

          remove_instance_variable(:@activejob_temporal_previous_transaction_setting)
          @activejob_temporal_transaction_safety_applied = false
          @activejob_temporal_transaction_setting_changed_after_safety = false
        end

        def restore_inherited_temporal_transaction_safety
          return if temporal_transaction_setting_explicit_locally?

          inherited_setting = inherited_temporal_transaction_previous_setting
          return if inherited_setting.equal?(INHERITED_TRANSACTION_SETTING_MISSING)

          apply_enqueue_after_transaction_commit_for_temporal(inherited_setting)
        end

        def apply_enqueue_after_transaction_commit_for_temporal(value)
          @activejob_temporal_setting_transaction_safety = true
          self.enqueue_after_transaction_commit = value
        ensure
          @activejob_temporal_setting_transaction_safety = false
        end

        def transaction_setting_before_temporal_safety(current_setting)
          inherited_setting = inherited_temporal_transaction_previous_setting
          return current_setting if inherited_setting.equal?(INHERITED_TRANSACTION_SETTING_MISSING)

          inherited_setting
        end

        def inherited_temporal_transaction_previous_setting
          return INHERITED_TRANSACTION_SETTING_MISSING unless superclass.respond_to?(
            :temporal_transaction_safety_applied?, true
          )

          if superclass.send(:temporal_transaction_safety_applied?)
            superclass.send(:temporal_previous_transaction_setting)
          else
            superclass.send(:inherited_temporal_transaction_previous_setting)
          end
        end

        def temporal_previous_transaction_setting
          @activejob_temporal_previous_transaction_setting
        end

        def temporal_transaction_setting_explicit?
          return true if temporal_transaction_setting_explicit_locally?
          return false unless superclass.respond_to?(:temporal_transaction_setting_explicit?, true)

          superclass.send(:temporal_transaction_setting_explicit?)
        end

        def temporal_transaction_setting_explicit_locally?
          @activejob_temporal_transaction_setting_explicit == true
        end

        def temporal_transaction_safety_applied?
          @activejob_temporal_transaction_safety_applied == true
        end

        def setting_temporal_transaction_safety?
          @activejob_temporal_setting_transaction_safety == true
        end

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
