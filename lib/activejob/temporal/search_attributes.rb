# frozen_string_literal: true

module ActiveJob
  module Temporal
    module SearchAttributes
      extend self

      def for(job)
        # Create Temporal search attributes with typed keys
        attributes = Temporalio::SearchAttributes.new

        # Define keys with proper types
        aj_class_key = Temporalio::SearchAttributes::Key.new("ajClass", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)
        aj_queue_key = Temporalio::SearchAttributes::Key.new("ajQueue", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)
        aj_job_id_key = Temporalio::SearchAttributes::Key.new("ajJobId", Temporalio::SearchAttributes::IndexedValueType::KEYWORD)
        aj_enqueued_at_key = Temporalio::SearchAttributes::Key.new("ajEnqueuedAt", Temporalio::SearchAttributes::IndexedValueType::TIME)

        # Set attribute values
        attributes[aj_class_key] = job.class.name
        attributes[aj_queue_key] = job.queue_name || "default"
        attributes[aj_job_id_key] = job.job_id
        attributes[aj_enqueued_at_key] = Time.now

        tenant_id = extract_tenant_id(job.arguments)
        if tenant_id
          aj_tenant_id_key = Temporalio::SearchAttributes::Key.new("ajTenantId", Temporalio::SearchAttributes::IndexedValueType::INTEGER)
          attributes[aj_tenant_id_key] = tenant_id
        end

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
