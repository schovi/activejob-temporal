# frozen_string_literal: true

# Ensure Rails logger is configured for stdout output in Docker environments
if ENV["RAILS_LOG_TO_STDOUT"] == "1" && defined?(Rails)
  Rails.logger = ActiveSupport::Logger.new($stdout)
  Rails.logger.level = Logger::INFO
  Rails.logger.formatter = Logger::Formatter.new
end

# Configure the ActiveJob Temporal adapter
ActiveJob::Temporal.configure do |config|
  # Temporal server address (default: "127.0.0.1:7233")
  config.target = ENV.fetch("TEMPORAL_TARGET", "127.0.0.1:7233")

  # Temporal namespace (default: "default")
  config.namespace = ENV.fetch("TEMPORAL_NAMESPACE", "default")

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
  config.max_payload_size_kb = 250
end

# Validate configuration
ActiveJob::Temporal.config.validate!
