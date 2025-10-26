# frozen_string_literal: true

module ActiveJob
  module Temporal
    module SearchAttributes
      extend self

      def for(job)
        attributes = {
          ajClass: job.class.name,
          ajQueue: job.queue_name || "default",
          ajJobId: job.job_id,
          ajEnqueuedAt: Time.now
        }

        tenant_id = extract_tenant_id(job.arguments)
        attributes[:ajTenantId] = tenant_id if tenant_id

        attributes
      end

      private

      def extract_tenant_id(arguments)
        first_argument = arguments&.first
        return unless first_argument.respond_to?(:tenant_id)

        first_argument.tenant_id
      end
    end
  end
end
