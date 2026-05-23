# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Workflows
      module WorkflowNexus
        private

        def nexus_client_for(endpoint:, service:)
          Temporalio::Workflow.create_nexus_client(endpoint: endpoint, service: service)
        end
      end
    end
  end
end
