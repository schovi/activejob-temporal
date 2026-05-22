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
    #     tctl admin cluster add-search-attributes --name ajTags --type KeywordList
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
    #   - ajTags: KEYWORD_LIST (optional, if tags are configured)
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
    #   # Find jobs tagged as urgent
    #   tctl workflow list --query "ajTags='urgent'"
    #
    # @see https://docs.temporal.io/visibility Search Attributes documentation
    module SearchAttributes
      extend self

      SEARCH_ATTRIBUTE_KEY_DEFINITIONS = {
        aj_class: ["ajClass", :KEYWORD],
        aj_queue: ["ajQueue", :KEYWORD],
        aj_job_id: ["ajJobId", :KEYWORD],
        aj_enqueued_at: ["ajEnqueuedAt", :TIME],
        aj_tenant_id: ["ajTenantId", :INTEGER],
        aj_tags: ["ajTags", :KEYWORD_LIST]
      }.freeze

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
      # @raise [ArgumentError] if job is nil
      # @raise [TypeError] if job does not respond to required methods
      # @raise [NameError] if Temporalio::SearchAttributes is not defined
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

        # Add job tags if available
        add_tags_attribute(attributes, job)

        attributes
      end

      private

      # Sets core search attributes (ajClass, ajQueue, ajJobId, ajEnqueuedAt).
      # @api private
      def set_core_attributes(attributes, job)
        attributes[search_attribute_key(:aj_class)] = job.class.name
        attributes[search_attribute_key(:aj_queue)] = job.queue_name || "default"
        attributes[search_attribute_key(:aj_job_id)] = job.job_id
        attributes[search_attribute_key(:aj_enqueued_at)] = Time.now
      end

      # Adds tenant ID attribute if first argument responds to tenant_id.
      # @api private
      def add_tenant_attribute(attributes, job)
        tenant_id = extract_tenant_id(job.arguments)
        return unless tenant_id

        attributes[search_attribute_key(:aj_tenant_id)] = tenant_id
      end

      def add_tags_attribute(attributes, job)
        tags = extract_tags(job)
        return if tags.empty?

        attributes[search_attribute_key(:aj_tags)] = tags
      end

      def search_attribute_key(key)
        search_attribute_keys.fetch(key)
      end

      def search_attribute_keys
        @search_attribute_keys ||= SEARCH_ATTRIBUTE_KEY_DEFINITIONS.each_with_object({}) do |(key, (name, type)), keys|
          keys[key] = create_key(name, type).freeze
        end.freeze
      end

      # Creates a typed Temporal search attribute key.
      # @api private
      def create_key(name, type)
        type_constant = Temporalio::SearchAttributes::IndexedValueType.const_get(type)
        Temporalio::SearchAttributes::Key.new(name, type_constant)
      end

      # Extracts tenant_id from first argument if it responds to tenant_id method.
      # @api private
      def extract_tenant_id(arguments)
        first_argument = arguments&.first
        return unless first_argument.respond_to?(:tenant_id)

        first_argument.tenant_id
      end

      def extract_tags(job)
        return [] unless job.respond_to?(:temporal_tags)

        job.temporal_tags || []
      end
    end
  end
end
