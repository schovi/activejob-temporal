# frozen_string_literal: true

require_relative "../audit_log"
require_relative "../logger"

module ActiveJob
  module Temporal
    module Activities
      class BestEffortSideEffects
        def initialize(audit_context)
          @audit_context = audit_context
        end

        def after_success(side_effect)
          yield
        rescue StandardError => e
          report_after_success(side_effect, e)
        end

        def after_failure(side_effect)
          yield
        rescue StandardError => e
          report_after_failure(side_effect, e)
        end

        def report_after_success(side_effect, error)
          report("activity_post_perform_side_effect_failed", side_effect, error)
        end

        def report_after_failure(side_effect, error)
          report("activity_failure_side_effect_failed", side_effect, error)
        end

        private

        def report(event_name, side_effect, error)
          ActiveJob::Temporal::Logger.warn(
            event_name,
            @audit_context.fetch(:attributes, {})
              .merge(side_effect: side_effect)
              .merge(ActiveJob::Temporal::AuditLog.error_attributes(error))
          )
        rescue StandardError
          nil
        end
      end
    end
  end
end
