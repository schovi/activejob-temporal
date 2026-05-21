# frozen_string_literal: true

module ActiveJob
  module Temporal
    module JobPayloadWorkflowInteractions
      private

      def apply_workflow_interactions(payload, job_class)
        workflow_interactions = workflow_interactions_for(job_class)
        payload[:workflow_interactions] = workflow_interactions if workflow_interactions
      end

      def workflow_interactions_for(job_class)
        handlers = {
          signals: handler_names_for(job_class, :temporal_signal_handler_names),
          queries: handler_names_for(job_class, :temporal_query_handler_names)
        }
        return if handlers.values.all?(&:empty?)

        { job_class: job_class.name, **handlers }
      end

      def handler_names_for(job_class, method_name)
        return [] unless job_class.respond_to?(method_name)

        job_class.public_send(method_name).map(&:to_s).sort
      end
    end
  end
end
