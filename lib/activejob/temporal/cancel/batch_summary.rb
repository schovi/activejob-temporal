# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Cancel
      class BatchSummary
        MAX_REPORTED_ERRORS = 100

        def initialize
          @mutex = Mutex.new
          @value = { terminated: 0, failed: 0, errors: [] }
        end

        def record_terminated
          mutex.synchronize { value[:terminated] += 1 }
        end

        def record_failure(workflow_id, run_id, error)
          mutex.synchronize do
            value[:failed] += 1
            if value[:errors].length < MAX_REPORTED_ERRORS
              value[:errors] << cancellation_error(workflow_id, run_id, error)
            end
          end
        end

        def to_h
          value
        end

        private

        attr_reader :mutex, :value

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
