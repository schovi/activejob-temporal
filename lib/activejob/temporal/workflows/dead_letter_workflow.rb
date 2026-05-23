# frozen_string_literal: true

require "time"
require "temporalio/workflow"

module ActiveJob
  module Temporal
    module Workflows
      class DeadLetterWorkflow < Temporalio::Workflow::Definition
        workflow_name :ActiveJobTemporalDeadLetterWorkflow

        workflow_query_attr_reader :entry

        workflow_signal
        def mark_retried(retry_workflow_id)
          if @entry
            mark_retried_entry(retry_workflow_id)
          else
            @pending_action = [:retried, retry_workflow_id]
          end
        end

        workflow_signal
        def discard(reason = nil)
          if @entry
            mark_discarded_entry(reason)
          else
            @pending_action = [:discarded, reason]
          end
        end

        def execute(entry)
          @entry = deep_stringify(entry)
          apply_pending_action
          wait_until_terminal_or_expired
          @entry
        end

        private

        def wait_until_terminal_or_expired
          auto_discard_after = auto_discard_after_seconds
          return Temporalio::Workflow.wait_condition { terminal? } unless auto_discard_after

          begin
            Temporalio::Workflow.timeout(
              auto_discard_after,
              Timeout::Error,
              "dead letter auto-discard expired",
              summary: "Dead letter auto-discard"
            ) do
              Temporalio::Workflow.wait_condition { terminal? }
            end
          rescue Timeout::Error
            mark_discarded_entry("auto_discard_after_expired")
          end
        end

        def auto_discard_after_seconds
          value = @entry.dig("metadata", "auto_discard_after_seconds")
          return if value.nil?

          seconds = Float(value)
          seconds if seconds.positive?
        rescue ArgumentError, TypeError
          nil
        end

        def apply_pending_action
          action, value = @pending_action
          @pending_action = nil

          case action
          when :retried then mark_retried_entry(value)
          when :discarded then mark_discarded_entry(value)
          end
        end

        def mark_retried_entry(retry_workflow_id)
          return if terminal?

          @entry["state"] = "retried"
          @entry["retry_workflow_id"] = retry_workflow_id
          @entry["retried_at"] = Temporalio::Workflow.now.iso8601
        end

        def mark_discarded_entry(reason)
          return if terminal?

          @entry["state"] = "discarded"
          @entry["discard_reason"] = reason if reason
          @entry["discarded_at"] = Temporalio::Workflow.now.iso8601
        end

        def terminal?
          %w[retried discarded].include?(@entry&.fetch("state", nil))
        end

        def deep_stringify(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, entry_value), hash|
              hash[key.to_s] = deep_stringify(entry_value)
            end
          when Array
            value.map { |entry_value| deep_stringify(entry_value) }
          else
            value
          end
        end
      end
    end
  end
end
