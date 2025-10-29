# frozen_string_literal: true

module ActiveJob
  module Temporal
    # Builds Temporal search attributes for job metadata.
    #
    # This module constructs typed search attributes that enable filtering and searching
    # workflows in the Temporal UI and via the Temporal API. Attributes include job class,
    # queue name, job ID, enqueued timestamp, and optionally tenant ID.
    #
    # @note Search Attribute Registration
    #   Search attributes MUST be pre-registered in the Temporal cluster with the correct
    #   type (KEYWORD, TIME, INTEGER, etc.) before use. Unregistered attributes will cause
    #   workflow start failures.
    #
    # @example Created attributes
    #   - ajClass: KEYWORD (job class name)
    #   - ajQueue: KEYWORD (queue name)
    #   - ajJobId: KEYWORD (unique job ID)
    #   - ajEnqueuedAt: TIME (enqueue timestamp)
    #   - ajTenantId: INTEGER (optional, if first argument responds to :tenant_id)
    #
    # @see https://docs.temporal.io/visibility Search Attributes documentation
    module SearchAttributes
      extend self

      # Builds a Temporalio::SearchAttributes object for a job.
      #
      # Creates typed search attribute keys and populates them with job metadata.
      # If `enable_search_attributes` is disabled in configuration, this should
      # still be called but may return an empty attributes object (handled by caller).
      #
      # @param job [ActiveJob::Base] The job instance to extract metadata from
      #
      # @return [Temporalio::SearchAttributes] Typed search attributes for Temporal
      #
      # @example Basic usage
      #   job = MyJob.new
      #   attributes = SearchAttributes.for(job)
      #   # attributes contains ajClass, ajQueue, ajJobId, ajEnqueuedAt
      #
      # @example With tenant ID
      #   class TenantJob < ApplicationJob
      #     def perform(tenant)
      #       # tenant.tenant_id is extracted automatically
      #     end
      #   end
      #   job = TenantJob.new(tenant)
      #   attributes = SearchAttributes.for(job)
      #   # attributes also contains ajTenantId
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
