# frozen_string_literal: true

# SimpleJob demonstrates basic job execution with no retry logic
# This is the simplest possible job that just executes once
class SimpleJob < ApplicationJob
  queue_as :default

  def perform(message)
    Rails.logger.info "SimpleJob executed with message: #{message}"
    # Simulate some work
    sleep 2
    Rails.logger.info "SimpleJob completed successfully"
  end
end
