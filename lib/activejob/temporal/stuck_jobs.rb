# frozen_string_literal: true

require "temporalio/client"

require_relative "search_attributes"
require_relative "visibility_query"
require_relative "workflow_types"

module ActiveJob
  module Temporal
    module StuckJobs
      DEFAULT_LIMIT = 100
      PROBLEMS_FILTER = "TemporalReportedProblems IN ('category=WorkflowTaskFailed', 'category=WorkflowTaskTimedOut')"
      CAPABILITY_ERROR = "stuck job detection is not available: requires Temporal server >= 1.30 with " \
                         "system.numConsecutiveWorkflowTaskProblemsToTriggerSearchAttribute > 0"

      module_function

      # Lists running job workflows with repeated workflow task failures or timeouts.
      #
      # @param job_class [Class, String, nil] Filter by ActiveJob class.
      # @param queue [String, nil] Filter by ActiveJob queue.
      # @param limit [Integer] Maximum number of results.
      # @param client [Temporalio::Client] Client for the namespace to inspect.
      # @return [Array<Hash>] Workflow details, job metadata, and reported problems.
      # @raise [ArgumentError] If the limit is invalid or a filter is unsafe.
      # @raise [ActiveJob::Temporal::Error] If reported problems are unavailable.
      # @note Requires Temporal Server >= 1.30 and a positive value for
      #   system.numConsecutiveWorkflowTaskProblemsToTriggerSearchAttribute.
      #   Temporal clears the problems on the next successful workflow task.
      #   The {ActiveJob::Temporal.cancel} method cannot fix a stuck workflow.
      def list(job_class: nil, queue: nil, limit: DEFAULT_LIMIT, client: ActiveJob::Temporal.client)
        VisibilityQuery.validate_limit!(limit)
        query = visibility_query(job_class, queue)
        check_capability!(client)

        query_visibility { client.list_workflows(query).first(limit) }.map { |workflow| entry(workflow) }
      end

      # Counts running job workflows with repeated workflow task failures or timeouts.
      #
      # @param job_class [Class, String, nil] Filter by ActiveJob class.
      # @param queue [String, nil] Filter by ActiveJob queue.
      # @param client [Temporalio::Client] Client for the namespace to inspect.
      # @return [Integer] Count from Temporal visibility.
      # @raise [ArgumentError] If a filter is unsafe.
      # @raise [ActiveJob::Temporal::Error] If reported problems are unavailable.
      # @note Requires Temporal Server >= 1.30 and a positive value for
      #   system.numConsecutiveWorkflowTaskProblemsToTriggerSearchAttribute.
      #   Temporal clears the problems on the next successful workflow task.
      #   The {ActiveJob::Temporal.cancel} method cannot fix a stuck workflow.
      def count(job_class: nil, queue: nil, client: ActiveJob::Temporal.client)
        query = visibility_query(job_class, queue)
        check_capability!(client)

        query_visibility { client.count_workflows(query).count }
      end

      def visibility_query(job_class, queue)
        workflow_types = [WorkflowTypes::ACTIVE_JOB, WorkflowTypes::DEAD_LETTER].map { |type| VisibilityQuery.quote(type) }
        filters = ["ExecutionStatus='Running'", "WorkflowType IN (#{workflow_types.join(', ')})", PROBLEMS_FILTER]
        unless job_class.nil?
          class_name = job_class.is_a?(Class) ? job_class.name : job_class
          filters << "#{attribute_name(:aj_class)}=#{VisibilityQuery.quote(class_name)}"
        end
        filters << "#{attribute_name(:aj_queue)}=#{VisibilityQuery.quote(queue)}" unless queue.nil?
        filters.join(" AND ")
      end
      private_class_method :visibility_query

      def check_capability!(client)
        request = Temporalio::Api::WorkflowService::V1::DescribeNamespaceRequest.new(namespace: client.namespace)
        response = client.workflow_service.describe_namespace(request)
        return if response.namespace_info&.capabilities&.reported_problems_search_attribute

        raise ActiveJob::Temporal::Error, CAPABILITY_ERROR
      end
      private_class_method :check_capability!

      def query_visibility
        yield
      rescue Temporalio::Error::RPCError => e
        raise unless e.code == Temporalio::Error::RPCError::Code::INVALID_ARGUMENT

        # The capability check already passed, so this is usually an unregistered ajClass/ajQueue attribute.
        raise ActiveJob::Temporal::Error.new("stuck job query rejected by Temporal: #{e.message}"), cause: e
      end
      private_class_method :query_visibility

      def entry(workflow)
        # Temporal returns "Datetime" for ajEnqueuedAt, which SDK 1.4.1 cannot decode as a typed key.
        attributes = workflow.raw_info.search_attributes&.indexed_fields
        {
          workflow_id: workflow.id,
          run_id: workflow.run_id,
          workflow_type: workflow.workflow_type,
          job_class: attribute_value(attributes, attribute_name(:aj_class)),
          job_id: attribute_value(attributes, attribute_name(:aj_job_id)),
          queue: attribute_value(attributes, attribute_name(:aj_queue)),
          started_at: workflow.start_time,
          problems: attribute_value(attributes, "TemporalReportedProblems") || []
        }
      end
      private_class_method :entry

      def attribute_value(attributes, name)
        payload = attributes&.[](name)
        Temporalio::Converters::PayloadConverter.default.from_payload(payload) if payload
      end
      private_class_method :attribute_value

      def attribute_name(key)
        SearchAttributes::SEARCH_ATTRIBUTE_KEY_DEFINITIONS.fetch(key).first
      end
      private_class_method :attribute_name
    end
  end
end
