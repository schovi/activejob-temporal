# frozen_string_literal: true

module ActiveJob
  module Temporal
    module SearchAttributes
      extend self

      def for(job)
        # Create Temporal search attributes with typed keys
        attributes = Temporalio::SearchAttributes.new

        # Define and set core attributes
        set_core_attributes(attributes, job)

        # Add tenant ID if available
        add_tenant_attribute(attributes, job)

        attributes
      end

      private

      def set_core_attributes(attributes, job)
        aj_class_key = create_key("ajClass", :KEYWORD)
        aj_queue_key = create_key("ajQueue", :KEYWORD)
        aj_job_id_key = create_key("ajJobId", :KEYWORD)
        aj_enqueued_at_key = create_key("ajEnqueuedAt", :TIME)

        attributes[aj_class_key] = job.class.name
        attributes[aj_queue_key] = job.queue_name || "default"
        attributes[aj_job_id_key] = job.job_id
        attributes[aj_enqueued_at_key] = Time.now
      end

      def add_tenant_attribute(attributes, job)
        tenant_id = extract_tenant_id(job.arguments)
        return unless tenant_id

        aj_tenant_id_key = create_key("ajTenantId", :INTEGER)
        attributes[aj_tenant_id_key] = tenant_id
      end

      def create_key(name, type)
        type_constant = Temporalio::SearchAttributes::IndexedValueType.const_get(type)
        Temporalio::SearchAttributes::Key.new(name, type_constant)
      end

      def extract_tenant_id(arguments)
        first_argument = arguments&.first
        return unless first_argument.respond_to?(:tenant_id)

        first_argument.tenant_id
      end
    end
  end
end
