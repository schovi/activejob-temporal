# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Cancel
      class BatchCanceller
        PAGE_SIZE = 100
        TERMINATION_REASON = "ActiveJob::Temporal.cancel_where"
        SEARCH_ATTRIBUTE_TYPES = {
          "ajClass" => :keyword,
          "ajQueue" => :keyword,
          "ajJobId" => :keyword,
          "ajEnqueuedAt" => :datetime,
          "ajTenantId" => :integer
        }.freeze

        def initialize(client)
          @client = client
        end

        def cancel_where(filters)
          query = workflows_query(normalize_filters(filters))
          summary = empty_summary

          each_workflow(query) do |workflow_execution|
            terminate_workflow(workflow_execution, summary)
          end

          summary
        rescue ArgumentError
          raise
        rescue StandardError => e
          raise ActiveJob::Temporal::TemporalConnectionError,
                "Failed to query Temporal workflows for batch cancellation: #{e.message}"
        end

        private

        attr_reader :client

        def normalize_filters(filters)
          unless filters.respond_to?(:to_hash)
            raise ArgumentError, "cancel_where filters must be a Hash of search attributes"
          end

          normalized_filters = filters.to_hash.transform_keys(&:to_s)
          raise ArgumentError, "cancel_where requires at least one search attribute" if normalized_filters.empty?

          normalized_filters.each_with_object({}) do |(name, value), result|
            result[validate_search_attribute_name!(name)] = format_search_attribute_value(name, value)
          end
        end

        def validate_search_attribute_name!(name)
          return name if SEARCH_ATTRIBUTE_TYPES.key?(name)

          supported_attributes = SEARCH_ATTRIBUTE_TYPES.keys.join(", ")
          raise ArgumentError,
                "Unsupported search attribute #{name.inspect}. Supported attributes: #{supported_attributes}"
        end

        def format_search_attribute_value(name, value)
          case SEARCH_ATTRIBUTE_TYPES.fetch(name)
          when :integer
            format_integer_search_attribute_value(name, value)
          when :keyword
            format_keyword_search_attribute_value(name, value)
          when :datetime
            format_datetime_search_attribute_value(name, value)
          end
        end

        def format_integer_search_attribute_value(name, value)
          return value.to_s if value.is_a?(Integer)

          raise ArgumentError, "#{name} must be an Integer"
        end

        def format_keyword_search_attribute_value(name, value)
          valid_value = value.is_a?(String) || value.is_a?(Symbol)
          raise ArgumentError, "#{name} must be a String or Symbol" unless valid_value

          quote_search_attribute_string(value.to_s)
        end

        def format_datetime_search_attribute_value(name, value)
          value = value.iso8601 if value.respond_to?(:iso8601)
          raise ArgumentError, "#{name} must be a String or ISO8601-compatible time value" unless value.is_a?(String)

          quote_search_attribute_string(value)
        end

        def quote_search_attribute_string(value)
          raise ArgumentError, "search attribute values cannot be empty" if value.empty?

          "'#{value.gsub("'", "''")}'"
        end

        def workflows_query(filters)
          (filters.map { |name, value| "#{name}=#{value}" } + ["ExecutionStatus='Running'"]).join(" AND ")
        end

        def empty_summary
          { terminated: 0, failed: 0, errors: [] }
        end

        def each_workflow(query, &)
          next_page_token = nil

          loop do
            page = client.list_workflow_page(query, page_size: PAGE_SIZE, next_page_token: next_page_token)
            page.executions.each(&)
            next_page_token = page.next_page_token
            break if next_page_token.to_s.empty?
          end
        end

        def terminate_workflow(workflow_execution, summary)
          workflow_id = workflow_execution.id
          run_id = workflow_execution.respond_to?(:run_id) ? workflow_execution.run_id : nil

          client.workflow_handle(workflow_id, run_id: run_id).terminate(TERMINATION_REASON)
          summary[:terminated] += 1
        rescue StandardError => e
          summary[:failed] += 1
          summary[:errors] << cancellation_error(workflow_id, run_id, e)
        end

        def cancellation_error(workflow_id, run_id, error)
          {
            workflow_id: workflow_id,
            run_id: run_id,
            error: "#{error.class}: #{error.message}"
          }
        end
      end
    end
  end
end
