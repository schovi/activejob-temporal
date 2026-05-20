# frozen_string_literal: true

# Ensure Rails logger is configured for stdout output in Docker environments
if ENV["RAILS_LOG_TO_STDOUT"] == "1" && defined?(Rails)
  Rails.logger = ActiveSupport::Logger.new($stdout)
  Rails.logger.level = Logger::INFO
  Rails.logger.formatter = Logger::Formatter.new
end

# Configure the ActiveJob Temporal adapter
# Note: Configuration is automatically validated at the end of this block
ActiveJob::Temporal.configure do |config|
  # Temporal server address (default: "127.0.0.1:7233")
  # Defaults to ENV["ACTIVEJOB_TEMPORAL_TARGET"] if not set
  config.target = ENV.fetch("ACTIVEJOB_TEMPORAL_TARGET", "127.0.0.1:7233")

  # Temporal namespace (default: "default")
  # Defaults to ENV["ACTIVEJOB_TEMPORAL_NAMESPACE"] if not set
  config.namespace = ENV.fetch("ACTIVEJOB_TEMPORAL_NAMESPACE", "default")

  # Task queue for workers (default: "default")
  # Defaults to ENV["ACTIVEJOB_TEMPORAL_TASK_QUEUE"] if not set
  config.task_queue = ENV.fetch("ACTIVEJOB_TEMPORAL_TASK_QUEUE", "default")

  # Task queue prefix for organizing workflows
  # If set, queues will be prefixed (e.g., "myapp-default")
  # config.task_queue_prefix = "basic_rails_app"

  # Activity execution timeout (default: 15 minutes)
  config.default_activity_timeout = 15.minutes

  # Retry policy defaults
  config.default_retry_initial_interval = 30.seconds
  config.default_retry_backoff = 2.0
  config.default_retry_max_attempts = 1

  # Logger (defaults to Rails.logger)
  config.logger = Rails.logger

  # Enable OpenTelemetry tracing (default: true)
  config.enable_tracing = true

  # Maximum payload size in KB (default: 250)
  # Defaults to ENV["ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB"] if not set
  config.max_payload_size_kb = ENV.fetch("ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB", 250).to_i

  # Maximum concurrent activities per worker (default: 100)
  # Defaults to ENV["ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES"] if not set
  config.max_concurrent_activities = ENV.fetch("ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES", 100).to_i

  # Maximum concurrent workflow tasks per worker (default: 5)
  # Defaults to ENV["ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS"] if not set
  config.max_concurrent_workflow_tasks = ENV.fetch("ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS", 5).to_i

  # Validation happens automatically at the end of this block!
end
