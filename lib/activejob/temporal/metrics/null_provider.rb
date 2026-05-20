# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Metrics
      class NullProvider
        def record_enqueue(job_class:, queue:, duplicate: false); end

        def observe_payload_size(job_class:, bytes:); end

        def instrument_perform(*)
          yield
        end

        def record_retry(job_class:, error:); end

        def record_worker_started; end

        def record_worker_stopped; end

        def record_active_tasks(count); end

        def render
          +""
        end
      end
    end
  end
end
