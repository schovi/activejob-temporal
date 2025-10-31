# frozen_string_literal: true

module ActiveJob
  module Temporal
    # Builds Temporal search attributes for job metadata.
    #
    # This module constructs typed search attributes that enable filtering and searching
    # workflows in the Temporal UI and via the Temporal API. Attributes include job class,
    # queue name, job ID, enqueued timestamp, and optionally tenant ID.
    #
    # @note Pre-Registration Required
    #   Search attributes MUST be pre-registered in the Temporal cluster with the correct
    #   type (KEYWORD, TIME, INTEGER, etc.) before use. Unregistered attributes will cause
    #   workflow start failures. Use the Temporal CLI to register attributes:
    #
    #     tctl admin cluster add-search-attributes --name ajClass --type Keyword
    #     tctl admin cluster add-search-attributes --name ajQueue --type Keyword
    #     tctl admin cluster add-search-attributes --name ajJobId --type Keyword
    #     tctl admin cluster add-search-attributes --name ajEnqueuedAt --type Datetime
    #     tctl admin cluster add-search-attributes --name ajTenantId --type Int
    #
    # @note Tenant ID Extraction
    #   The module automatically extracts tenant_id from the first job argument if it
    #   responds to the `tenant_id` method. This supports multi-tenant architectures
    #   where jobs operate on tenant-specific data.
    #
    # @example Created attributes
    #   - ajClass: KEYWORD (job class name)
    #   - ajQueue: KEYWORD (queue name)
    #   - ajJobId: KEYWORD (unique job ID)
    #   - ajEnqueuedAt: TIME (enqueue timestamp)
    #   - ajTenantId: INTEGER (optional, if first argument responds to :tenant_id)
    #
    # @example Querying with search attributes (Temporal CLI)
    #   # Find all jobs in the "mailers" queue
    #   tctl workflow list --query "ajQueue='mailers'"
    #
    #   # Find specific job by ID
    #   tctl workflow list --query "ajJobId='abc-123'"
    #
    #   # Find all tenant jobs enqueued today
    #   tctl workflow list --query "ajTenantId=42 AND ajEnqueuedAt > '2025-10-31T00:00:00Z'"
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
      # @raise [Temporalio::Error::WorkflowUpdateFailedError] if attributes are not pre-registered in Temporal
      #
      # @example Basic usage
      #   job = MyJob.new
      #   attributes = SearchAttributes.for(job)
      #   # attributes contains ajClass, ajQueue, ajJobId, ajEnqueuedAt
      #
      # @example With tenant ID (automatic extraction)
      #   class TenantJob < ApplicationJob
      #     def perform(tenant)
      #       # tenant.tenant_id is extracted automatically
      #     end
      #   end
      #   tenant = Tenant.find(42)
      #   job = TenantJob.new(tenant)
      #   attributes = SearchAttributes.for(job)
      #   # attributes also contains ajTenantId: 42
      #
      # @example Without tenant ID
      #   job = MyJob.new("plain_string_arg")
      #   attributes = SearchAttributes.for(job)
      #   # attributes does NOT contain ajTenantId (first arg doesn't respond to tenant_id)
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
