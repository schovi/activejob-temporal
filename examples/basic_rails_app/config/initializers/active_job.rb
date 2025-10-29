# frozen_string_literal: true

# Configure ActiveJob to use the Temporal adapter
# This must be set before any jobs are loaded
Rails.application.config.active_job.queue_adapter = :temporal
