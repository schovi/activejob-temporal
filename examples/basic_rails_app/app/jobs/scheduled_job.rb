# frozen_string_literal: true

# ScheduledJob demonstrates delayed/scheduled execution
# Use .set(wait: duration) or .set(wait_until: timestamp) to schedule
class ScheduledJob < ApplicationJob
  queue_as :default

  def perform(message, scheduled_at = nil)
    Rails.logger.info "ScheduledJob executed with message: #{message}"
    Rails.logger.info "Originally scheduled at: #{scheduled_at}" if scheduled_at
    Rails.logger.info "Executed at: #{Time.current}"

    # Simulate some work
    sleep 1
    Rails.logger.info "ScheduledJob completed successfully"
  end
end
