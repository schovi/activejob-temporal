# frozen_string_literal: true

# CancellableJob demonstrates graceful cancellation with heartbeating
# Heartbeating allows Temporal to cancel the job mid-execution
class CancellableJob < ApplicationJob
  queue_as :default

  temporal_options start_to_close_timeout: 2.minutes, heartbeat_timeout: 10.seconds

  def perform(iterations = 10)
    Rails.logger.info "CancellableJob started with #{iterations} iterations"

    iterations.times do |i|
      # Send heartbeat to Temporal - this allows cancellation to be detected
      Temporalio::Activity::Context.current.heartbeat

      Rails.logger.info "CancellableJob: Iteration #{i + 1}/#{iterations}"
      sleep 2 # Simulate work

      # If the job is cancelled, the next heartbeat will raise an exception
      # and the job will stop gracefully
    end

    Rails.logger.info "CancellableJob completed all iterations successfully"
  rescue Temporalio::Error::ActivityCancelledError => e
    Rails.logger.warn "CancellableJob was cancelled: #{e.message}"
    # Perform any cleanup here if needed
    raise # Re-raise to mark the job as cancelled in Temporal
  end
end
