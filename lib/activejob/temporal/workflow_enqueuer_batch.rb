# frozen_string_literal: true

require_relative "batch_enqueuer"

module ActiveJob
  module Temporal
    module WorkflowEnqueuerBatch
      def enqueue_batch(items, concurrency: 1)
        BatchEnqueuer.new(
          enqueue: method(:enqueue),
          validate_job: method(:validate_job_for_enqueueing),
          validate_scheduled_at: method(:validate_scheduled_at!)
        ).enqueue(items, concurrency: concurrency)
      end
    end
  end
end
