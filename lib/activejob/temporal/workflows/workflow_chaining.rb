# frozen_string_literal: true

require_relative "../activities/aj_runner_activity"

module ActiveJob
  module Temporal
    module Workflows
      module WorkflowChaining
        WORKFLOW_CONTROL_FIELDS = %i[
          default_activity_options
          retry_policy
          temporal_options
          dead_letter
          rate_limits
          activity_task_queue
          local_activity_helpers
        ].freeze

        private

        def execute_activity_sequence(payload)
          result = execute_activity_payload(payload)
          execute_chain_sequence(payload, result) do |chain_payload|
            yield chain_payload if block_given?
          end
        end

        def execute_chain_sequence(payload, result)
          chain_payloads(payload).each_with_index do |chain_payload, index|
            workflow_state["chain_index"] = index + 1
            raw_arguments = [result]
            activity_payload = payload_with_raw_arguments(chain_payload, raw_arguments)
            yield activity_payload if block_given?
            result = execute_activity_payload(activity_payload, raw_arguments: raw_arguments)
          end
          result
        ensure
          workflow_state.delete("chain_index")
        end

        def execute_activity_payload(payload, raw_arguments: nil)
          wait_for_rate_limit(payload)
          wait_while_paused

          workflow_state["phase"] = "running_activity"
          Temporalio::Workflow.execute_activity(
            *activity_arguments(payload, raw_arguments),
            **activity_options(payload)
          )
        end

        def activity_arguments(payload, raw_arguments)
          arguments = [
            ActiveJob::Temporal::Activities::AjRunnerActivity,
            payload
          ]
          arguments << raw_arguments unless raw_arguments.nil?
          arguments
        end

        def chain_payloads(payload)
          Array(payload[:chain] || payload["chain"]).each_with_index.map do |chain_step, index|
            chain_step_payload(payload, chain_step, index + 1)
          end
        end

        def chain_step_payload(root_payload, chain_step, position)
          return normalize_chain_step_payload(chain_step) if full_chain_step_payload?(chain_step)

          options = chain_step_options(chain_step)
          payload = base_chain_step_payload(root_payload, chain_step, options, position)

          copy_workflow_control_fields(root_payload, payload)
          payload.merge!(options)
          payload
        end

        def full_chain_step_payload?(chain_step)
          payload_value(chain_step, :job_id) &&
            payload_value(chain_step, :queue_name) &&
            !payload_value(chain_step, :arguments).nil?
        end

        def normalize_chain_step_payload(chain_step)
          chain_step.each_with_object({}) do |(key, value), normalized|
            normalized[key.to_s] = value
          end
        end

        def base_chain_step_payload(root_payload, chain_step, options, position)
          {
            "job_class" => payload_value(chain_step, :job_class),
            "job_id" => "#{payload_value(root_payload, :job_id)}:chain:#{position}",
            "queue_name" => (options["queue"] || "default").to_s,
            "arguments" => [],
            "executions" => 0,
            "exception_executions" => {}
          }
        end

        def chain_step_options(chain_step)
          options = payload_value(chain_step, :options) || {}
          options.each_with_object({}) do |(key, value), normalized|
            normalized[key.to_s] = value
          end
        end

        def copy_workflow_control_fields(source_payload, target_payload)
          WORKFLOW_CONTROL_FIELDS.each do |key|
            value = payload_value(source_payload, key)
            next unless value

            target_payload[key.to_s] = key == :dead_letter ? chain_dead_letter_metadata(value, target_payload) : value
          end
        end

        def chain_dead_letter_metadata(metadata, payload)
          metadata.transform_keys(&:to_s).merge(
            "job_class" => payload.fetch("job_class"),
            "job_id" => payload.fetch("job_id"),
            "queue_name" => payload.fetch("queue_name")
          )
        end

        def payload_value(payload, key)
          payload[key] || payload[key.to_s]
        end

        def payload_with_raw_arguments(payload, raw_arguments)
          key = payload.key?(:arguments) ? :arguments : "arguments"
          payload.merge(key => raw_arguments)
        end
      end
    end
  end
end
