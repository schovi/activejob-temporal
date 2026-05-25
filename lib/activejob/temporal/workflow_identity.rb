# frozen_string_literal: true

require "active_job"
require "active_support/concern"

module ActiveJob
  module Temporal
    module WorkflowIdentity
      extend ActiveSupport::Concern

      UNSET = Object.new.freeze
      CONTROL_CHARACTER_PATTERN = /[[:cntrl:]]/

      def self.normalize_identity_value(value, label)
        raise ArgumentError, "#{label} must be a String" unless value.is_a?(String)

        normalized = value.strip
        raise ArgumentError, "#{label} must be present" if normalized.empty?
        raise ArgumentError, "#{label} must be valid UTF-8" unless normalized.valid_encoding?

        if normalized.match?(CONTROL_CHARACTER_PATTERN)
          raise ArgumentError, "#{label} cannot contain control characters"
        end

        normalized
      end

      class_methods do
        def temporal_workflow_name(name = UNSET)
          unless name.equal?(UNSET)
            @temporal_workflow_name = WorkflowIdentity.normalize_identity_value(name, "temporal_workflow_name")
          end

          @temporal_workflow_name
        end

        def temporal_workflow_id(&block)
          if block
            @temporal_workflow_id_strategy = block
            @temporal_workflow_id_prefix = nil
          end

          @temporal_workflow_id_strategy
        end

        def temporal_workflow_id_prefix(prefix = UNSET)
          unless prefix.equal?(UNSET)
            @temporal_workflow_id_prefix = WorkflowIdentity.normalize_identity_value(
              prefix,
              "temporal_workflow_id_prefix"
            )
            @temporal_workflow_id_strategy = nil
          end

          @temporal_workflow_id_prefix
        end
      end
    end
  end
end

ActiveJob::Base.include(ActiveJob::Temporal::WorkflowIdentity) if defined?(ActiveJob::Base)
