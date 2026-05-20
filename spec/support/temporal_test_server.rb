# frozen_string_literal: true

# Integration tests rely on a running Temporal server.
# Start one locally before running specs, for example:
#   temporal server start-dev --namespace test
# Or use Docker:
#   docker run --rm -p 7233:7233 -p 8233:8233 temporalio/auto-setup:latest

module TemporalTestHelper
  TEST_NAMESPACE = "test"
  DEFAULT_TARGET = "127.0.0.1:7233"
  INTEGRATION_PATH_SEGMENT = File.join("spec", "integration")

  class ServerNotAvailableError < RuntimeError
  end

  class << self
    def client
      ensure_setup!
      ActiveJob::Temporal.client
    end

    def ensure_setup!
      return if @setup

      ensure_temporal_sdk!
      store_original_configuration
      configure_temporal_for_tests
      begin
        verify_connection!
        @setup = true
      rescue StandardError => e
        raise_missing_server_error(e)
      end
    rescue StandardError
      teardown
      raise
    end

    def teardown
      @setup = false
      restore_original_configuration
      clear_client!
    end

    def integration_suite_requested?
      return true unless defined?(RSpec)

      files_to_run = RSpec.configuration.files_to_run
      return true if files_to_run.empty?

      files_to_run.any? { |path| path.include?(INTEGRATION_PATH_SEGMENT) }
    end

    private

    def ensure_temporal_sdk!
      return if defined?(Temporalio::Client)

      raise "Temporal Ruby SDK (temporalio gem) must be available to run integration specs."
    end

    def store_original_configuration
      return @store_original_configuration if defined?(@store_original_configuration)

      @store_original_configuration = {
        target: ActiveJob::Temporal.config.target,
        namespace: ActiveJob::Temporal.config.namespace,
        task_queue_prefix: ActiveJob::Temporal.config.task_queue_prefix
      }
    end

    def configure_temporal_for_tests
      ActiveJob::Temporal.configure do |config|
        config.target = ENV.fetch("TEMPORAL_TEST_TARGET", DEFAULT_TARGET)
        config.namespace = TEST_NAMESPACE
      end
      clear_client!
    end

    def verify_connection!
      client = ActiveJob::Temporal.client
      client.list_workflow_page(nil, page_size: 1)
    end

    def restore_original_configuration
      return unless @store_original_configuration

      ActiveJob::Temporal.configure do |config|
        config.target = @store_original_configuration[:target]
        config.namespace = @store_original_configuration[:namespace]
        config.task_queue_prefix = @store_original_configuration[:task_queue_prefix]
      end
      @store_original_configuration = nil
    end

    def clear_client!
      ActiveJob::Temporal.instance_variable_set(:@client, nil)
    end

    def raise_missing_server_error(error)
      target = ENV.fetch("TEMPORAL_TEST_TARGET", DEFAULT_TARGET)
      message = <<~MSG
        Unable to connect to Temporal test server at #{target} (namespace: #{TEST_NAMESPACE}).
        Start a test server before running integration specs, for example:
          temporal server start-dev --namespace #{TEST_NAMESPACE}
        Or with Docker:
          docker run --rm -p 7233:7233 -p 8233:8233 temporalio/auto-setup:latest
        Original error: #{error.class}: #{error.message}
      MSG
      raise ServerNotAvailableError, message
    end
  end
end

RSpec.configure do |config|
  config.before(:suite) do
    TemporalTestHelper.ensure_setup! if TemporalTestHelper.integration_suite_requested?
  end

  config.after(:suite) do
    TemporalTestHelper.teardown
  end
end
