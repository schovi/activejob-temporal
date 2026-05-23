# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Workflows
      module WorkflowInteractions
        HANDLER_NAME_PATTERN = /\A[a-zA-Z_]\w*\z/

        private

        def pause_workflow(args)
          workflow_state["paused"] = true
          workflow_state["pause_reason"] = args.first if args.any?
          record_signal("pause", args)
          nil
        end

        def resume_workflow(args)
          workflow_state["paused"] = false
          workflow_state.delete("pause_reason")
          record_signal("resume", args)
          nil
        end

        def dispatch_custom_signal(handler_name, args)
          unless workflow_interactions_configured?
            buffered_custom_signals << [handler_name, deep_copy(args)]
            return nil
          end

          dispatch_configured_custom_signal(handler_name, args)
        end

        def dispatch_configured_custom_signal(handler_name, args)
          handler = workflow_signal_handlers[handler_name]
          raise ArgumentError, "Unknown workflow signal: #{handler_name}" unless handler

          handler.call(workflow_state["custom"], *args)
          record_signal(handler_name, args)
          nil
        end

        def dispatch_custom_query(handler_name, args)
          handler = workflow_query_handlers[handler_name]
          raise ArgumentError, "Unknown workflow query: #{handler_name}" unless handler

          handler.call(deep_copy(workflow_state["custom"]), *args)
        end

        def dispatch_custom_update(handler_name, args)
          handler = workflow_update_handlers[handler_name]
          raise ArgumentError, "Unknown workflow update: #{handler_name}" unless handler

          result = handler.call(workflow_state["custom"], *args)
          record_update(handler_name, args)
          result
        end

        def record_signal(handler_name, args)
          workflow_state["signals"][handler_name] = {
            "args" => deep_copy(args),
            "received_at" => Temporalio::Workflow.now.iso8601
          }
        end

        def record_update(handler_name, args)
          workflow_state["updates"][handler_name] = {
            "args" => deep_copy(args),
            "accepted_at" => Temporalio::Workflow.now.iso8601
          }
        end

        def configure_workflow_state(payload)
          workflow_state["job_class"] = payload[:job_class] || payload["job_class"]
          workflow_state["job_id"] = payload[:job_id] || payload["job_id"]
          workflow_state["queue_name"] = payload[:queue_name] || payload["queue_name"]
          workflow_state["phase"] = "initialized"
        end

        def configure_workflow_interactions(payload)
          reset_workflow_interactions
          load_workflow_interaction_handlers(payload)
          @workflow_interactions_configured = true
          flush_buffered_custom_signals
        end

        def reset_workflow_interactions
          @workflow_signal_handlers = {}
          @workflow_query_handlers = {}
          @workflow_update_handlers = {}
        end

        def load_workflow_interaction_handlers(payload)
          metadata = payload[:workflow_interactions] || payload["workflow_interactions"]
          return unless metadata

          job_class = constant_from_name(metadata[:job_class] || metadata["job_class"])
          return unless job_class

          @workflow_signal_handlers = filtered_handlers(
            job_class,
            :temporal_signal_handlers,
            metadata[:signals] || metadata["signals"]
          )
          @workflow_query_handlers = filtered_handlers(
            job_class,
            :temporal_query_handlers,
            metadata[:queries] || metadata["queries"]
          )
          @workflow_update_handlers = filtered_handlers(
            job_class,
            :temporal_update_handlers,
            metadata[:updates] || metadata["updates"]
          )
        end

        def workflow_state
          @workflow_state ||= {
            "phase" => "initialized",
            "paused" => false,
            "signals" => {},
            "updates" => {},
            "custom" => {}
          }
        end

        def workflow_signal_handlers
          @workflow_signal_handlers ||= {}
        end

        def workflow_query_handlers
          @workflow_query_handlers ||= {}
        end

        def workflow_update_handlers
          @workflow_update_handlers ||= {}
        end

        def workflow_interactions_configured?
          @workflow_interactions_configured == true
        end

        def buffered_custom_signals
          @buffered_custom_signals ||= []
        end

        def flush_buffered_custom_signals
          buffered_custom_signals.shift(buffered_custom_signals.length).each do |handler_name, args|
            dispatch_configured_custom_signal(handler_name, args)
          end
        end

        def filtered_handlers(job_class, method_name, handler_names)
          return {} unless job_class.respond_to?(method_name)

          allowed_names = Array(handler_names).map(&:to_s)
          job_class.public_send(method_name).each_with_object({}) do |(name, handler), handlers|
            handler_name = name.to_s
            handlers[handler_name] = handler if allowed_names.include?(handler_name)
          end
        end

        def constant_from_name(class_name)
          class_name.to_s.split("::").reject(&:empty?).reduce(Object) do |namespace, constant_name|
            namespace.const_get(constant_name, false)
          end
        rescue NameError
          nil
        end

        def normalize_handler_name!(name, handler_type)
          handler_name = name.to_s
          return handler_name if handler_name.match?(HANDLER_NAME_PATTERN)

          raise ArgumentError, "#{handler_type} names must start with a letter or underscore and contain word chars"
        end

        def wait_while_paused
          return unless workflow_state["paused"]

          workflow_state["phase"] = "paused"
          Temporalio::Workflow.wait_condition { !workflow_state["paused"] }
        end

        def deep_copy(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, entry_value), hash|
              hash[key.to_s] = deep_copy(entry_value)
            end
          when Array
            value.map { |entry_value| deep_copy(entry_value) }
          else
            value
          end
        end
      end
    end
  end
end
