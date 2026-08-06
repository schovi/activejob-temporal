# frozen_string_literal: true

require "spec_helper"
require "base64"
require "tmpdir"

describe ActiveJob::Temporal::Configuration do
  let(:configuration) { described_class.new }

  def assert_configuration_error(expected_message)
    error = assert_raises(ActiveJob::Temporal::ConfigurationError) do
      configuration.validate!
    end

    assert_error_message expected_message, error
  end

  def assert_error_message(expected_message, error)
    case expected_message
    when Regexp
      assert_match expected_message, error.message
    else
      assert_equal expected_message, error.message
    end
  end

  def configuration_with_env(env_var, value)
    configuration_with_environment(env_var => value)
  end

  def configuration_with_environment(overrides)
    with_environment(overrides) { described_class.new }
  end

  def with_environment(overrides)
    missing_value = Object.new
    original_values = overrides.to_h do |key, _value|
      [key, ENV.key?(key) ? ENV.fetch(key) : missing_value]
    end

    overrides.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end

    yield
  ensure
    original_values&.each do |key, value|
      value.equal?(missing_value) ? ENV.delete(key) : ENV[key] = value
    end
  end

  def warning_logger_recorder
    Class.new do
      attr_reader :warnings

      def initialize
        @warnings = []
      end

      def warn(message)
        warnings << message
      end
    end.new
  end

  def boolean_env_attributes
    {
      "ACTIVEJOB_TEMPORAL_AUDIT_LOG" => :audit_log,
      "ACTIVEJOB_TEMPORAL_ENCRYPT_PAYLOAD" => :encrypt_payload,
      "ACTIVEJOB_TEMPORAL_TLS_CERT_WATCH" => :tls_cert_watch
    }
  end

  describe "defaults" do
    it "sets the Temporal endpoint" do
      assert_equal "127.0.0.1:7233", configuration.target
    end

    it "sets the namespace" do
      assert_equal "default", configuration.namespace
    end

    it "sets task queue prefix to nil" do
      assert_nil configuration.task_queue_prefix
    end

    it "configures activity timeout" do
      assert_equal 15.minutes, configuration.default_activity_timeout
    end

    it "configures retry initial interval" do
      assert_equal 30.seconds, configuration.default_retry_initial_interval
    end

    it "configures retry backoff" do
      assert_equal 2.0, configuration.default_retry_backoff
    end

    it "configures retry max attempts" do
      assert_equal 1, configuration.default_retry_max_attempts
    end

    it "initializes observability configuration" do
      assert_kind_of ActiveJob::Temporal::Observability::Configuration, configuration.observability
      refute configuration.observability.enabled?
    end

    it "sets identity to nil by default" do
      assert_nil configuration.identity
    end

    it "sets max_concurrent_activities to 100" do
      assert_equal 100, configuration.max_concurrent_activities
    end

    it "sets max_concurrent_workflow_tasks to 5" do
      assert_equal 5, configuration.max_concurrent_workflow_tasks
    end

    it "leaves continue-as-new threshold disabled by default" do
      assert_nil configuration.continue_as_new_history_event_threshold
    end

    it "sets bounded dependency wait defaults" do
      assert_equal 1.day, configuration.dependency_wait_timeout
      assert_equal 10.seconds, configuration.dependency_wait_initial_interval
      assert_equal 1.minute, configuration.dependency_wait_max_interval
      assert_equal 2.0, configuration.dependency_wait_backoff
    end

    it "disables local activity helpers by default" do
      assert_equal [], configuration.local_activity_helpers
    end

    it "sets task_queue to 'default'" do
      assert_equal "default", configuration.task_queue
    end

    it "sets TLS rotation defaults" do
      assert_nil configuration.tls
      assert_nil configuration.tls_cert_path
      assert_nil configuration.tls_key_path
      assert_nil configuration.tls_server_root_ca_cert_path
      assert_nil configuration.tls_domain
      assert_equal false, configuration.tls_cert_watch
      assert_equal "HUP", configuration.tls_reload_signal
    end

    it "sets API key and worker registration defaults" do
      assert_nil configuration.api_key
      assert_nil configuration.api_key_file
      assert_equal false, configuration.api_key_watch
      assert_equal [], configuration.worker_activities
      assert_equal true, configuration.worker_activejob_workloads
      assert_equal 0.0, configuration.graceful_shutdown_period
    end

    it "sets priority task queue mappings to an empty hash" do
      assert_equal({}, configuration.priority_task_queues)
    end

    it "disables dead letter queue routing by default" do
      assert_nil configuration.dead_letter_queue
      assert_nil configuration.dead_letter_after_attempts
      assert_nil configuration.dead_letter_auto_discard_after
    end

    it "disables observability adapters by default" do
      assert_equal [], configuration.observability.adapters
    end

    it "disables audit logging by default" do
      assert_equal false, configuration.audit_log
      assert_nil configuration.audit_logger
    end

    it "disables payload encryption by default" do
      assert_equal false, configuration.encrypt_payload
      assert_nil configuration.encryption_key
      assert_equal [], configuration.encryption_old_keys
    end

    it "uses JSON payload serialization by default" do
      assert_same :json, configuration.payload_serializer
    end

    it "disables external payload storage by default" do
      assert_nil configuration.payload_storage_adapter
      assert_nil configuration.payload_storage_threshold_kb
    end

    it "uses the default workflow ID generator when none is configured" do
      assert_nil configuration.workflow_id_generator
    end

    it "disables rate limiting by default" do
      assert_nil configuration.rate_limiter
      assert_nil configuration.global_rate_limit
    end

    it "sets an empty middleware chain" do
      assert_kind_of ActiveJob::Temporal::Middleware::Chain, configuration.middleware_chain
      assert_empty configuration.middleware_chain.to_a
    end

    it "uses strict validation by default" do
      assert_same :strict, configuration.validation_level
    end
  end

  describe "environment variable support" do
    before do
      ActiveJob::Temporal.instance_variable_set(:@config_mvar, nil)
    end

    it "reads target from ACTIVEJOB_TEMPORAL_TARGET environment variable" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_TARGET" => "custom:9999")

      assert_equal "custom:9999", config.target
    end

    it "uses default target when ACTIVEJOB_TEMPORAL_TARGET is not set" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_TARGET" => nil)

      assert_equal "127.0.0.1:7233", config.target
    end

    it "reads namespace from ACTIVEJOB_TEMPORAL_NAMESPACE environment variable" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_NAMESPACE" => "production")

      assert_equal "production", config.namespace
    end

    it "uses default namespace when ACTIVEJOB_TEMPORAL_NAMESPACE is not set" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_NAMESPACE" => nil)

      assert_equal "default", config.namespace
    end

    it "reads task_queue_prefix from ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX environment variable" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX" => "my-app-")

      assert_equal "my-app-", config.task_queue_prefix
    end

    it "uses default task_queue_prefix (nil) when ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX is not set" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX" => nil)

      assert_nil config.task_queue_prefix
    end

    it "reads task_queue from ACTIVEJOB_TEMPORAL_TASK_QUEUE environment variable" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_TASK_QUEUE" => "critical")

      assert_equal "critical", config.task_queue
    end

    it "uses default task_queue ('default') when ACTIVEJOB_TEMPORAL_TASK_QUEUE is not set" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_TASK_QUEUE" => nil)

      assert_equal "default", config.task_queue
    end

    it "reads max_payload_size_kb from ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB and converts to integer" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB" => "512")

      assert_equal 512, config.max_payload_size_kb
    end

    it "reads payload serializer from ACTIVEJOB_TEMPORAL_PAYLOAD_SERIALIZER" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_PAYLOAD_SERIALIZER" => "message_pack")

      assert_same :message_pack, config.payload_serializer
    end

    it "uses default max_payload_size_kb when ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB is not set" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB" => nil)

      assert_equal 250, config.max_payload_size_kb
    end

    it "handles multiple environment variables set simultaneously" do
      config = configuration_with_environment(
        "ACTIVEJOB_TEMPORAL_TARGET" => "temporal.prod:7233",
        "ACTIVEJOB_TEMPORAL_NAMESPACE" => "production",
        "ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX" => "app-",
        "ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB" => "1024"
      )

      assert_equal "temporal.prod:7233", config.target
      assert_equal "production", config.namespace
      assert_equal "app-", config.task_queue_prefix
      assert_equal 1024, config.max_payload_size_kb
    end

    it "allows explicit configuration to override environment variables" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_TARGET" => "env-target:7233")
      config.target = "explicit-target:8888"

      assert_equal "explicit-target:8888", config.target
    end

    it "validates environment variable values when validate! is called" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_TARGET" => "invalid-format")

      error = assert_raises(ActiveJob::Temporal::ConfigurationError) { config.validate! }
      assert_match(/[Tt]arget must.*host:port/, error.message)
    end

    it "reads max_concurrent_activities from ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES and converts to integer" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES" => "200")

      assert_equal 200, config.max_concurrent_activities
    end

    it "uses default max_concurrent_activities when ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES is not set" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES" => nil)

      assert_equal 100, config.max_concurrent_activities
    end

    it "reads max_concurrent_workflow_tasks from ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS env var" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS" => "300")

      assert_equal 300, config.max_concurrent_workflow_tasks
    end

    it "reads continue-as-new threshold from ACTIVEJOB_TEMPORAL_CONTINUE_AS_NEW_HISTORY_EVENT_THRESHOLD" do
      env_var = "ACTIVEJOB_TEMPORAL_CONTINUE_AS_NEW_HISTORY_EVENT_THRESHOLD"
      config = configuration_with_environment(env_var => "10000")

      assert_equal 10_000, config.continue_as_new_history_event_threshold
    end

    it "reads dependency wait settings from environment variables" do
      config = configuration_with_environment(
        "ACTIVEJOB_TEMPORAL_DEPENDENCY_WAIT_TIMEOUT_SECONDS" => "120",
        "ACTIVEJOB_TEMPORAL_DEPENDENCY_WAIT_INITIAL_INTERVAL_SECONDS" => "2",
        "ACTIVEJOB_TEMPORAL_DEPENDENCY_WAIT_MAX_INTERVAL_SECONDS" => "30",
        "ACTIVEJOB_TEMPORAL_DEPENDENCY_WAIT_BACKOFF" => "3.5"
      )

      assert_equal 120.0, config.dependency_wait_timeout
      assert_equal 2.0, config.dependency_wait_initial_interval
      assert_equal 30.0, config.dependency_wait_max_interval
      assert_equal 3.5, config.dependency_wait_backoff
    end

    it "reads dead letter queue settings from environment variables" do
      auto_discard_env = "ACTIVEJOB_TEMPORAL_DEAD_LETTER_AUTO_DISCARD_AFTER_SECONDS"
      config = configuration_with_environment(
        "ACTIVEJOB_TEMPORAL_DEAD_LETTER_QUEUE" => "failed_jobs",
        "ACTIVEJOB_TEMPORAL_DEAD_LETTER_AFTER_ATTEMPTS" => "3",
        auto_discard_env => "86400"
      )

      assert_equal "failed_jobs", config.dead_letter_queue
      assert_equal 3, config.dead_letter_after_attempts
      assert_equal 86_400.0, config.dead_letter_auto_discard_after
    end

    it "reads audit logging from ACTIVEJOB_TEMPORAL_AUDIT_LOG" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_AUDIT_LOG" => "true")

      assert_equal true, config.audit_log
    end

    it "accepts common truthy boolean environment values" do
      boolean_env_attributes.each do |env_var, attribute|
        %w[true TRUE 1 yes on].each do |value|
          config = configuration_with_env(env_var, value)

          assert_equal true, config.public_send(attribute)
        end
      end
    end

    it "accepts common falsey boolean environment values" do
      boolean_env_attributes.each do |env_var, attribute|
        %w[false FALSE 0 no off].each do |value|
          config = configuration_with_env(env_var, value)

          assert_equal false, config.public_send(attribute)
        end
      end
    end

    it "rejects invalid boolean environment values" do
      boolean_env_attributes.each_key do |env_var|
        error = assert_raises(ActiveJob::Temporal::ConfigurationError) do
          configuration_with_env(env_var, "definitely")
        end
        assert_match(/Invalid boolean value for #{env_var}: "definitely"/, error.message)
      end
    end

    it "reads payload encryption from ACTIVEJOB_TEMPORAL_ENCRYPT_PAYLOAD" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_ENCRYPT_PAYLOAD" => "true")

      assert_equal true, config.encrypt_payload
    end

    it "reads encryption key from ACTIVEJOB_TEMPORAL_ENCRYPTION_KEY" do
      key = valid_encryption_key
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_ENCRYPTION_KEY" => key)

      assert_equal key, config.encryption_key
    end

    it "reads TLS certificate paths from environment variables" do
      config = configuration_with_environment(
        "ACTIVEJOB_TEMPORAL_TLS_CERT_PATH" => "/certs/client.pem",
        "ACTIVEJOB_TEMPORAL_TLS_KEY_PATH" => "/certs/client-key.pem",
        "ACTIVEJOB_TEMPORAL_TLS_SERVER_ROOT_CA_CERT_PATH" => "/certs/ca.pem",
        "ACTIVEJOB_TEMPORAL_TLS_DOMAIN" => "temporal.example.dev"
      )

      assert_equal "/certs/client.pem", config.tls_cert_path
      assert_equal "/certs/client-key.pem", config.tls_key_path
      assert_equal "/certs/ca.pem", config.tls_server_root_ca_cert_path
      assert_equal "temporal.example.dev", config.tls_domain
    end

    it "reads TLS reload controls from environment variables" do
      config = configuration_with_environment(
        "ACTIVEJOB_TEMPORAL_TLS_CERT_WATCH" => "true",
        "ACTIVEJOB_TEMPORAL_TLS_RELOAD_SIGNAL" => "USR1"
      )

      assert_equal true, config.tls_cert_watch
      assert_equal "USR1", config.tls_reload_signal
    end

    it "uses default (5) when ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS is not set" do
      config = configuration_with_environment("ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS" => nil)

      assert_equal 5, config.max_concurrent_workflow_tasks
    end
  end

  describe "#logger" do
    it "falls back to a standard logger when Rails is unavailable" do
      assert_kind_of Logger, configuration.logger
    end

    it "uses Rails.logger when Rails responds to logger" do
      rails_logger = Logger.new(StringIO.new)
      stub_const("Rails", Class.new do
        class << self
          attr_accessor :logger
        end
      end)
      Rails.logger = rails_logger

      assert_same rails_logger, described_class.new.logger
    end
  end

  describe "#inspect" do
    it "redacts encryption keys and TLS settings" do
      configuration.encryption_key = valid_encryption_key("primary")
      configuration.encryption_old_keys = [valid_encryption_key("previous")]
      configuration.tls = { client_private_key: "-----BEGIN PRIVATE KEY-----" }

      output = configuration.inspect

      refute_includes output, valid_encryption_key("primary")
      refute_includes output, valid_encryption_key("previous")
      refute_includes output, "BEGIN PRIVATE KEY"
      assert_includes output, "encryption_key=\"[FILTERED]\""
      assert_includes output, "encryption_old_keys=\"[FILTERED]\""
      assert_includes output, "tls=\"[FILTERED]\""
    end

    it "keeps non-secret attributes visible" do
      configuration.target = "temporal.example.com:7233"

      output = configuration.inspect

      assert_includes output, "target=\"temporal.example.com:7233\""
      assert_includes output, "encryption_key=nil"
      assert_includes output, "tls=nil"
    end

    it "redacts the api_key" do
      configuration.api_key = "super-secret-token"

      output = configuration.inspect

      refute_includes output, "super-secret-token"
      assert_includes output, "api_key=\"[FILTERED]\""
    end
  end

  describe "#task_queue_prefix=" do
    it "accepts nil values" do
      configuration.task_queue_prefix = nil
      assert_nil configuration.task_queue_prefix
    end
  end

  describe "#priority_task_queues=" do
    it "accepts priority to task queue mappings" do
      configuration.priority_task_queues = { 10 => "high_priority", 90 => "low_priority" }

      assert_equal({ 10 => "high_priority", 90 => "low_priority" }, configuration.priority_task_queues)
    end

    it "rejects non-hash values" do
      configuration.priority_task_queues = "high_priority"

      assert_configuration_error(/Priority task queues must be a hash/)
    end

    it "rejects non-integer priority keys" do
      configuration.priority_task_queues = { high: "high_priority" }

      assert_configuration_error(/priority keys must be integers/)
    end

    it "rejects blank task queue names" do
      configuration.priority_task_queues = { 10 => " " }

      assert_configuration_error(/task queue names must be present/)
    end
  end

  describe "#payload_storage_adapter=" do
    it "accepts adapters that respond to dump and load with a positive threshold" do
      adapter = Class.new do
        def dump(_payload, metadata:); end
        def load(_reference); end
      end.new

      configuration.payload_storage_adapter = adapter
      configuration.payload_storage_threshold_kb = 200

      configuration.validate!
    end

    it "rejects adapters missing the required methods" do
      configuration.payload_storage_adapter = Object.new
      configuration.payload_storage_threshold_kb = 200

      assert_configuration_error(/Payload storage adapter must respond to #dump and #load/)
    end

    it "requires a threshold when an adapter is configured" do
      adapter = Class.new do
        def dump(_payload, metadata:); end
        def load(_reference); end
      end.new

      configuration.payload_storage_adapter = adapter

      assert_configuration_error(/Payload storage threshold kb is required/)
    end

    it "requires an adapter when a threshold is configured" do
      configuration.payload_storage_threshold_kb = 200

      assert_configuration_error(/Payload storage threshold kb requires payload_storage_adapter/)
    end

    it "rejects non-positive thresholds" do
      adapter = Class.new do
        def dump(_payload, metadata:); end
        def load(_reference); end
      end.new

      configuration.payload_storage_adapter = adapter
      configuration.payload_storage_threshold_kb = 0

      assert_configuration_error(/Payload storage threshold kb must be a positive integer/)
    end
  end

  describe "#dead_letter_queue=" do
    it "accepts nil and non-blank task queue names" do
      configuration.dead_letter_queue = "failed_jobs"
      assert_equal "failed_jobs", configuration.dead_letter_queue

      configuration.dead_letter_queue = nil
      assert_nil configuration.dead_letter_queue
    end

    it "rejects blank task queue names" do
      configuration.dead_letter_queue = " "

      assert_configuration_error(/Dead letter queue must be present/)
    end
  end

  describe "#dead_letter_after_attempts=" do
    it "accepts nil and positive integer thresholds" do
      configuration.dead_letter_queue = "failed_jobs"
      configuration.dead_letter_after_attempts = 3
      assert_equal 3, configuration.dead_letter_after_attempts

      configuration.dead_letter_after_attempts = nil
      assert_nil configuration.dead_letter_after_attempts
    end

    it "rejects zero and negative thresholds" do
      configuration.dead_letter_queue = "failed_jobs"

      configuration.dead_letter_after_attempts = 0
      assert_configuration_error(/Dead letter after attempts must be greater than 0/)

      configuration.dead_letter_after_attempts = -1
      assert_configuration_error(/Dead letter after attempts must be greater than 0/)
    end

    it "requires a dead letter queue when a threshold is configured" do
      configuration.dead_letter_after_attempts = 3

      assert_configuration_error(/requires dead_letter_queue/)
    end
  end

  describe "#dead_letter_auto_discard_after=" do
    it "accepts nil and positive durations" do
      configuration.dead_letter_queue = "failed_jobs"
      configuration.dead_letter_auto_discard_after = 7.days
      assert_equal 7.days, configuration.dead_letter_auto_discard_after

      configuration.dead_letter_auto_discard_after = nil
      assert_nil configuration.dead_letter_auto_discard_after
    end

    it "rejects zero and negative durations" do
      configuration.dead_letter_queue = "failed_jobs"

      configuration.dead_letter_auto_discard_after = 0
      assert_configuration_error(/Dead letter auto discard after must be positive/)

      configuration.dead_letter_auto_discard_after = -1
      assert_configuration_error(/Dead letter auto discard after must be positive/)
    end

    it "requires a dead letter queue when configured" do
      configuration.dead_letter_auto_discard_after = 1.day

      assert_configuration_error(/requires dead_letter_queue/)
    end
  end

  describe "#observability=" do
    it "accepts observability configuration objects" do
      observability = ActiveJob::Temporal::Observability::Configuration.new

      configuration.observability = observability

      assert_same observability, configuration.observability
      configuration.validate!
    end

    it "rejects invalid observability configuration objects" do
      configuration.observability = "bad"

      assert_configuration_error(/Observability must be an observability configuration/)
    end
  end

  describe "#audit_log=" do
    it "accepts boolean values" do
      configuration.audit_log = true
      assert_equal true, configuration.audit_log

      configuration.audit_log = false
      assert_equal false, configuration.audit_log
    end

    it "rejects non-boolean values" do
      configuration.audit_log = "true"

      assert_configuration_error(/Audit log must be true or false/)
    end
  end

  describe "#audit_logger=" do
    it "accepts nil and logger-compatible values" do
      logger = Logger.new(StringIO.new)

      configuration.audit_logger = logger
      assert_same logger, configuration.audit_logger

      configuration.audit_logger = nil
      assert_nil configuration.audit_logger
    end

    it "rejects values without info logging support" do
      configuration.audit_logger = Object.new

      assert_configuration_error(/Audit logger must respond to #info/)
    end
  end

  describe "#encrypt_payload=" do
    it "accepts boolean values when encryption key configuration is valid" do
      configuration.encryption_key = valid_encryption_key

      configuration.encrypt_payload = true
      assert_equal true, configuration.encrypt_payload

      configuration.encrypt_payload = false
      assert_equal false, configuration.encrypt_payload
    end

    it "rejects non-boolean values" do
      configuration.encrypt_payload = "true"

      assert_configuration_error(/Encrypt payload must be true or false/)
    end

    it "requires a primary encryption key when enabled" do
      configuration.encrypt_payload = true

      assert_configuration_error(/Encryption key is required/)
    end
  end

  describe "#encryption_key=" do
    it "accepts nil and Base64-encoded 32-byte keys" do
      configuration.encryption_key = valid_encryption_key
      assert_equal valid_encryption_key, configuration.encryption_key

      configuration.encryption_key = nil
      assert_nil configuration.encryption_key
    end

    it "accepts key metadata with an explicit id" do
      key_metadata = { id: "2026-05", key: valid_encryption_key }

      configuration.encryption_key = key_metadata

      assert_equal key_metadata, configuration.encryption_key
    end

    it "rejects keys that are not valid Base64" do
      configuration.encryption_key = "not base64"

      assert_configuration_error(/Encryption key must be a Base64-encoded 32-byte/)
    end

    it "rejects key metadata with unsafe ids" do
      configuration.encryption_key = { id: "bad key", key: valid_encryption_key }

      assert_configuration_error(/Encryption key must be a Base64-encoded 32-byte/)
    end

    it "rejects Base64 keys with the wrong decoded length" do
      short_key = Base64.strict_encode64("short")

      configuration.encryption_key = short_key

      assert_configuration_error(/Encryption key must be a Base64-encoded 32-byte/)
    end
  end

  describe "#encryption_old_keys=" do
    it "accepts an array of Base64-encoded 32-byte keys" do
      old_keys = [valid_encryption_key("old-1"), valid_encryption_key("old-2")]

      configuration.encryption_old_keys = old_keys

      assert_equal old_keys, configuration.encryption_old_keys
    end

    it "accepts old key metadata with explicit ids" do
      old_keys = [
        { id: "2026-01", key: valid_encryption_key("old-1") },
        { id: "2026-02", key: valid_encryption_key("old-2"), decrypt_until: Time.utc(2027, 1, 1) }
      ]

      configuration.encryption_old_keys = old_keys

      assert_equal old_keys, configuration.encryption_old_keys
    end

    it "rejects non-array values" do
      configuration.encryption_old_keys = valid_encryption_key

      assert_configuration_error(/Encryption old keys must be an array/)
    end

    it "rejects arrays containing invalid keys" do
      configuration.encryption_old_keys = [valid_encryption_key, "invalid"]

      assert_configuration_error(/Encryption old keys must contain only/)
    end
  end

  describe "#payload_serializer=" do
    it "accepts built-in payload serializers" do
      configuration.payload_serializer = :message_pack
      assert_same :message_pack, configuration.payload_serializer

      configuration.payload_serializer = :msgpack
      assert_same :msgpack, configuration.payload_serializer

      configuration.payload_serializer = :marshal
      assert_same :marshal, configuration.payload_serializer

      configuration.payload_serializer = :json
      assert_same :json, configuration.payload_serializer
    end

    it "rejects unsupported payload serializers" do
      configuration.payload_serializer = :yaml

      assert_configuration_error(/Payload serializer is not supported/)
    end
  end

  describe "#workflow_id_generator=" do
    it "accepts callable values" do
      generator = ->(job) { "custom:#{job.job_id}" }

      configuration.workflow_id_generator = generator

      assert_same generator, configuration.workflow_id_generator
    end

    it "accepts nil values" do
      configuration.workflow_id_generator = nil

      assert_nil configuration.workflow_id_generator
    end

    it "rejects non-callable values" do
      configuration.workflow_id_generator = "custom-id"

      assert_configuration_error(/Workflow id generator must respond to #call/)
    end

    it "rejects callables that cannot accept a job argument" do
      configuration.workflow_id_generator = -> { "custom-id" }

      assert_configuration_error(/must accept one positional ActiveJob argument/)
    end

    it "rejects keyword-only callables" do
      configuration.workflow_id_generator = ->(job:) { "custom:#{job.job_id}" }

      assert_configuration_error(/one positional ActiveJob argument/)
    end
  end

  describe "#rate_limiter=" do
    it "accepts nil and limiter backends" do
      limiter = Class.new do
        def wait_time_for(_rate_limits)
          0
        end
      end.new

      configuration.rate_limiter = limiter
      assert_same limiter, configuration.rate_limiter

      configuration.rate_limiter = nil
      assert_nil configuration.rate_limiter
    end

    it "accepts callable limiter backends" do
      limiter = ->(_rate_limits) { 0 }

      configuration.rate_limiter = limiter

      assert_same limiter, configuration.rate_limiter
    end

    it "rejects unsupported limiter backends" do
      configuration.rate_limiter = Object.new

      assert_configuration_error(/Rate limiter must respond to #wait_time_for or #call/)
    end

    it "rejects limiter backends that do not accept rate limits" do
      configuration.rate_limiter = -> { 0 }

      assert_configuration_error(/Rate limiter must accept one rate_limits argument/)
    end
  end

  describe "#global_rate_limit=" do
    it "accepts normalized global rate limit hashes when a limiter is configured" do
      configuration.rate_limiter = ->(_rate_limits) { 0 }

      configuration.global_rate_limit = { limit: 100, per: :second }

      assert_equal({ limit: 100, per: :second }, configuration.global_rate_limit)
    end

    it "requires a limiter backend" do
      configuration.global_rate_limit = { limit: 100, per: :second }

      assert_configuration_error(/Global rate limit requires rate_limiter/)
    end

    it "rejects invalid global rate limit hashes" do
      configuration.rate_limiter = ->(_rate_limits) { 0 }

      configuration.global_rate_limit = { limit: 0, per: :second }

      assert_configuration_error(/Global rate limit must be a hash/)
    end
  end

  describe "#add_middleware" do
    it "registers middleware in the configured chain" do
      events = []
      middleware_class = Class.new do
        def initialize(events)
          @events = events
        end

        def call(_job)
          @events << :before
          result = yield
          @events << :after
          result
        end
      end

      registered = configuration.add_middleware(middleware_class, events)

      assert_equal [registered], configuration.middleware_chain.to_a
      assert_equal %i[before perform after], configuration.middleware_chain.call(:job) { events << :perform }
    end

    it "rejects invalid middleware chain replacements" do
      configuration.middleware_chain = Object.new

      assert_configuration_error(/Middleware chain must respond to #add and #call/)
    end
  end

  describe "#validation_level=" do
    it "accepts supported validation levels" do
      configuration.validation_level = :warn
      assert_same :warn, configuration.validation_level

      configuration.validation_level = :none
      assert_same :none, configuration.validation_level
    end

    it "rejects unsupported validation levels" do
      configuration.validation_level = :relaxed

      assert_configuration_error(/Validation level must be one of/)
    end
  end

  describe "TLS configuration" do
    def with_tls_files
      Dir.mktmpdir do |directory|
        cert_path = File.join(directory, "client.pem")
        key_path = File.join(directory, "client-key.pem")
        root_ca_path = File.join(directory, "root-ca.pem")
        File.write(cert_path, "cert")
        File.write(key_path, "key")
        File.write(root_ca_path, "root-ca")
        yield cert_path, key_path, root_ca_path
      end
    end

    it "accepts readable client certificate and key paths" do
      with_tls_files do |cert_path, key_path, root_ca_path|
        configuration.in_configure_block = true
        configuration.tls_cert_path = cert_path
        configuration.tls_key_path = key_path
        configuration.tls_server_root_ca_cert_path = root_ca_path
        configuration.tls_domain = "temporal.example.dev"
        configuration.tls_cert_watch = true
        configuration.in_configure_block = false

        configuration.validate!
      end
    end

    it "rejects a client certificate path without a matching key path" do
      with_tls_files do |cert_path, _key_path, _root_ca_path|
        configuration.tls_cert_path = cert_path

        assert_configuration_error(/requires tls_key_path/)
      end
    end

    it "rejects unreadable TLS paths" do
      missing_path = File.join(Dir.tmpdir, "missing-root-ca.pem")

      configuration.tls_server_root_ca_cert_path = missing_path

      assert_configuration_error(/readable regular file/)
    end

    it "accepts symlinked TLS paths so Kubernetes secret mounts work" do
      with_tls_files do |cert_path, key_path, _root_ca_path|
        symlink_path = "#{cert_path}.link"
        File.symlink(cert_path, symlink_path)
        configuration.in_configure_block = true
        configuration.tls_cert_path = symlink_path
        configuration.tls_key_path = key_path
        configuration.in_configure_block = false

        configuration.validate!
      end
    end

    it "rejects symlinked TLS paths pointing at a directory" do
      with_tls_files do |cert_path, key_path, _root_ca_path|
        symlink_path = "#{cert_path}.link"
        File.symlink(File.dirname(cert_path), symlink_path)
        configuration.in_configure_block = true
        configuration.tls_cert_path = symlink_path
        configuration.tls_key_path = key_path
        configuration.in_configure_block = false

        assert_configuration_error(/readable regular file/)
      end
    end

    it "rejects certificate watching when no TLS file paths are configured" do
      configuration.tls_cert_watch = true

      assert_configuration_error(/requires at least one TLS certificate path/)
    end

    it "rejects non-boolean certificate watching values" do
      configuration.tls_cert_watch = "true"

      assert_configuration_error(/must be true or false/)
    end

    it "rejects API key watching without an api_key_file" do
      configuration.api_key_watch = true

      assert_configuration_error(/requires api_key_file/)
    end

    it "rejects unreadable api_key_file paths" do
      configuration.api_key_file = File.join(Dir.tmpdir, "missing-temporal-token")

      assert_configuration_error(/readable regular file/)
    end

    it "rejects disabling the ActiveJob workloads with no custom activities" do
      configuration.worker_activejob_workloads = false

      assert_configuration_error(/requires worker_activities/)
    end

    it "rejects a negative graceful shutdown period" do
      configuration.graceful_shutdown_period = -1

      assert_configuration_error(/>= 0 seconds/)
    end

    it "rejects blank TLS domain overrides" do
      configuration.tls_domain = " "

      assert_configuration_error(/must be present/)
    end

    it "accepts trappable TLS reload signal names" do
      configuration.tls_reload_signal = "SIGHUP"

      assert_equal "SIGHUP", configuration.tls_reload_signal
    end

    it "rejects invalid or reserved TLS reload signal names" do
      %w[HUP! HUP123 9 CHLD INT KILL PIPE QUIT STOP TERM].each do |signal_name|
        configuration.tls_reload_signal = signal_name

        assert_configuration_error(/must be a signal name/)
      end
    end
  end

  describe "configuration attribute methods" do
    it "defines getter and setter methods for every configuration attribute" do
      explicit_methods = described_class.instance_methods(false)

      ActiveJob::Temporal::CONFIGURATION_ATTRIBUTES.each_key do |attribute|
        assert_includes explicit_methods, attribute
        assert_includes explicit_methods, :"#{attribute}="
      end
    end

    it "does not define dynamic dispatch hooks for configuration attributes" do
      explicit_methods = described_class.instance_methods(false)

      refute_includes explicit_methods, :method_missing
      refute_includes explicit_methods, :respond_to_missing?
    end

    it "raises NoMethodError for unknown attribute getter" do
      error = assert_raises(NoMethodError) { configuration.unknown_attribute }
      assert_match(/undefined method.*unknown_attribute/, error.message)
    end

    it "raises NoMethodError for unknown attribute setter" do
      error = assert_raises(NoMethodError) { configuration.unknown_attribute = "value" }
      assert_match(/undefined method.*unknown_attribute=/, error.message)
    end

    it "returns false for respond_to? with unknown attribute" do
      assert_equal false, configuration.respond_to?(:unknown_attribute)
      assert_equal false, configuration.respond_to?(:unknown_attribute=)
    end

    it "returns true for respond_to? with known attributes" do
      assert_equal true, configuration.respond_to?(:target)
      assert_equal true, configuration.respond_to?(:target=)
      assert_equal true, configuration.respond_to?(:namespace)
      assert_equal true, configuration.respond_to?(:namespace=)
    end

    it "defers validation for known attribute setters" do
      validate_calls = call_recorded_method(configuration, :validate!)

      configuration.target = "invalid target"

      refute_called validate_calls, :validate!
      assert_equal "invalid target", configuration.target
    end
  end

  describe "#default_activity_timeout=" do
    it "accepts positive durations" do
      configuration.default_activity_timeout = 10.seconds
      assert_equal 10.seconds, configuration.default_activity_timeout
    end

    it "raises when duration is zero or negative" do
      configuration.default_activity_timeout = 0
      assert_configuration_error(/must be positive/)

      configuration.default_activity_timeout = -5
      assert_configuration_error(/must be positive/)
    end

    it "raises when value cannot be coerced into a duration" do
      configuration.default_activity_timeout = Object.new

      assert_configuration_error(/must be a duration/)
    end
  end

  describe "#default_retry_initial_interval=" do
    it "accepts positive durations" do
      configuration.default_retry_initial_interval = 5.seconds
      assert_equal 5.seconds, configuration.default_retry_initial_interval
    end

    it "raises when duration is zero or negative" do
      configuration.default_retry_initial_interval = 0.seconds

      assert_configuration_error(/must be positive/)
    end

    it "raises when value lacks numeric semantics" do
      configuration.default_retry_initial_interval = Object.new

      assert_configuration_error(/must be a duration/)
    end
  end

  describe "dependency wait validation" do
    it "accepts valid dependency wait settings" do
      configuration.dependency_wait_timeout = 10.minutes
      configuration.dependency_wait_initial_interval = 5.seconds
      configuration.dependency_wait_max_interval = 30.seconds
      configuration.dependency_wait_backoff = 2.5

      configuration.validate!
    end

    it "rejects non-positive dependency wait durations" do
      configuration.dependency_wait_timeout = 0.seconds

      assert_configuration_error(/Dependency wait timeout must be positive/)
    end

    it "rejects dependency wait max interval below the initial interval" do
      configuration.dependency_wait_initial_interval = 30.seconds
      configuration.dependency_wait_max_interval = 5.seconds

      assert_configuration_error(/Dependency wait max interval must be greater than or equal to initial interval/)
    end

    it "rejects dependency wait backoff below 1" do
      configuration.dependency_wait_backoff = 0.9

      assert_configuration_error(/Dependency wait backoff must be greater than or equal to 1/)
    end
  end

  describe "#validate!" do
    describe "with valid configuration" do
      it "does not raise any errors with default values" do
        configuration.validate!
      end

      it "does not raise errors with all valid custom values" do
        configuration.target = "temporal.example.com:7233"
        configuration.namespace = "production-namespace"
        configuration.default_activity_timeout = 10.minutes
        configuration.default_retry_initial_interval = 5.seconds
        configuration.default_retry_backoff = 2.5
        configuration.default_retry_max_attempts = 5
        configuration.max_payload_size_kb = 500

        configuration.validate!
      end
    end

    describe "when target is invalid" do
      it "accepts DNS names, localhost, and IPv4 host targets" do
        %w[localhost:7233 temporal.example.com:7233 127.0.0.1:7233].each do |target|
          configuration.in_configure_block = true
          configuration.target = target
          configuration.in_configure_block = false

          configuration.validate!
        end
      end

      it "raises ConfigurationError for missing port" do
        configuration.in_configure_block = true
        configuration.target = "localhost"
        configuration.in_configure_block = false
        assert_configuration_error(/[Tt]arget must.*host:port/)
      end

      it "raises ConfigurationError for missing host" do
        configuration.in_configure_block = true
        configuration.target = ":7233"
        configuration.in_configure_block = false
        assert_configuration_error(/[Tt]arget must.*host:port/)
      end

      it "raises ConfigurationError for invalid format" do
        configuration.in_configure_block = true
        configuration.target = "badformat"
        configuration.in_configure_block = false
        assert_configuration_error(/[Tt]arget must.*host:port/)
      end

      it "raises ConfigurationError for port number too long" do
        configuration.in_configure_block = true
        configuration.target = "localhost:123456"
        configuration.in_configure_block = false
        assert_configuration_error(/[Tt]arget must.*host:port/)
      end

      it "raises ConfigurationError for ports outside the TCP range" do
        configuration.in_configure_block = true
        configuration.target = "localhost:65536"
        configuration.in_configure_block = false
        assert_configuration_error(/[Tt]arget must.*host:port/)
      end

      it "raises ConfigurationError for invalid characters" do
        configuration.in_configure_block = true
        configuration.target = "host with spaces:7233"
        configuration.in_configure_block = false
        assert_configuration_error(/[Tt]arget must.*host:port/)
      end

      it "raises ConfigurationError for invalid host labels" do
        %w[_temporal:7233 .temporal:7233 temporal.:7233 temporal-.example.com:7233].each do |target|
          configuration.in_configure_block = true
          configuration.target = target
          configuration.in_configure_block = false

          assert_configuration_error(/[Tt]arget must.*host:port/)
        end
      end

      it "raises ConfigurationError when target is nil" do
        configuration.in_configure_block = true
        configuration.target = nil
        configuration.in_configure_block = false
        assert_configuration_error(/Target host is required|Target must be in format/)
      end
    end

    describe "when namespace is invalid" do
      it "raises ConfigurationError for spaces in namespace" do
        configuration.in_configure_block = true
        configuration.namespace = "has spaces"
        configuration.in_configure_block = false
        assert_configuration_error(/[Nn]amespace must/)
      end

      it "raises ConfigurationError for special characters" do
        configuration.in_configure_block = true
        configuration.namespace = "special!chars"
        configuration.in_configure_block = false
        assert_configuration_error(/[Nn]amespace must/)
      end

      it "raises ConfigurationError for dots in namespace" do
        configuration.in_configure_block = true
        configuration.namespace = "namespace.with.dots"
        configuration.in_configure_block = false
        assert_configuration_error(/[Nn]amespace must/)
      end

      it "raises ConfigurationError for namespaces that do not start and end alphanumeric" do
        %w[_namespace namespace_ -namespace namespace-].each do |namespace|
          configuration.in_configure_block = true
          configuration.namespace = namespace
          configuration.in_configure_block = false

          assert_configuration_error(/[Nn]amespace must/)
        end
      end

      it "raises ConfigurationError for namespaces longer than the Temporal ID limit" do
        configuration.in_configure_block = true
        configuration.namespace = "a" * 1001
        configuration.in_configure_block = false
        assert_configuration_error(/[Nn]amespace must/)
      end

      it "raises ConfigurationError when namespace is nil" do
        configuration.in_configure_block = true
        configuration.namespace = nil
        configuration.in_configure_block = false
        assert_configuration_error(/Namespace is required|namespace must contain only alphanumeric/)
      end

      it "accepts valid namespace with hyphens and underscores" do
        configuration.in_configure_block = true
        configuration.namespace = "valid-namespace_123"
        configuration.in_configure_block = false
        configuration.validate!
      end
    end

    describe "when timeouts are invalid" do
      it "raises ConfigurationError when default_activity_timeout is zero" do
        configuration.in_configure_block = true
        configuration[:default_activity_timeout] = 0
        configuration.in_configure_block = false
        assert_configuration_error(/[Dd]efault activity timeout.*must be positive/)
      end

      it "raises ConfigurationError when default_activity_timeout is negative" do
        configuration.in_configure_block = true
        configuration[:default_activity_timeout] = -5
        configuration.in_configure_block = false
        assert_configuration_error(/[Dd]efault activity timeout.*must be positive/)
      end

      it "raises ConfigurationError when default_retry_initial_interval is zero" do
        configuration.in_configure_block = true
        configuration[:default_retry_initial_interval] = 0.seconds
        configuration.in_configure_block = false
        assert_configuration_error(/[Dd]efault retry initial interval.*must be positive/)
      end

      it "raises ConfigurationError when default_retry_initial_interval is negative" do
        configuration.in_configure_block = true
        configuration[:default_retry_initial_interval] = -10
        configuration.in_configure_block = false
        assert_configuration_error(/[Dd]efault retry initial interval.*must be positive/)
      end

      it "raises ConfigurationError when timeout is not a duration" do
        configuration.in_configure_block = true
        configuration[:default_activity_timeout] = "not a duration"
        configuration.in_configure_block = false
        assert_configuration_error(/[Dd]efault activity timeout.*must be a duration/)
      end
    end

    describe "when retry settings are invalid" do
      it "raises ConfigurationError when backoff is less than 1.0" do
        configuration.in_configure_block = true
        configuration.default_retry_backoff = 0.5
        configuration.in_configure_block = false
        assert_configuration_error(/[Dd]efault retry backoff.*>= 1\.0/)
      end

      it "raises ConfigurationError when backoff is zero" do
        configuration.in_configure_block = true
        configuration.default_retry_backoff = 0.0
        configuration.in_configure_block = false
        assert_configuration_error(/[Dd]efault retry backoff.*>= 1\.0/)
      end

      it "raises ConfigurationError when backoff is negative" do
        configuration.in_configure_block = true
        configuration.default_retry_backoff = -1.0
        configuration.in_configure_block = false
        assert_configuration_error(/[Dd]efault retry backoff.*>= 1\.0/)
      end

      it "accepts backoff exactly equal to 1.0" do
        configuration.in_configure_block = true
        configuration.default_retry_backoff = 1.0
        configuration.in_configure_block = false
        configuration.validate!
      end

      it "raises ConfigurationError when max_attempts is negative" do
        configuration.in_configure_block = true
        configuration.default_retry_max_attempts = -1
        configuration.in_configure_block = false
        assert_configuration_error(/[Dd]efault retry max attempts.*>= 0/)
      end

      it "accepts max_attempts equal to zero" do
        configuration.in_configure_block = true
        configuration.default_retry_max_attempts = 0
        configuration.in_configure_block = false
        configuration.validate!
      end
    end

    describe "when payload size is invalid" do
      it "raises ConfigurationError when exceeding maximum limit" do
        configuration.in_configure_block = true
        configuration.max_payload_size_kb = 2_097_153
        configuration.in_configure_block = false
        assert_configuration_error(/[Mm]ax payload size.*2,097,152/)
      end

      it "raises ConfigurationError when far exceeding maximum limit" do
        configuration.in_configure_block = true
        configuration.max_payload_size_kb = 5_000_000
        configuration.in_configure_block = false
        assert_configuration_error(/[Mm]ax payload size.*2,097,152/)
      end

      it "accepts payload size at the maximum limit" do
        configuration.in_configure_block = true
        configuration.max_payload_size_kb = 2_097_152
        configuration.in_configure_block = false
        configuration.validate!
      end

      it "raises ConfigurationError when payload size is zero" do
        configuration.in_configure_block = true
        configuration.max_payload_size_kb = 0
        configuration.in_configure_block = false
        assert_configuration_error(/[Mm]ax payload size.*(must be positive|between 1)/)
      end

      it "raises ConfigurationError when payload size is negative" do
        configuration.in_configure_block = true
        configuration.max_payload_size_kb = -100
        configuration.in_configure_block = false
        assert_configuration_error(/[Mm]ax payload size.*(must be positive|between 1)/)
      end

      it "accepts a reasonable payload size" do
        configuration.in_configure_block = true
        configuration.max_payload_size_kb = 1024
        configuration.in_configure_block = false
        configuration.validate!
      end
    end

    describe "when worker concurrency settings are invalid" do
      it "raises ConfigurationError when max_concurrent_activities is zero" do
        configuration.in_configure_block = true
        configuration.max_concurrent_activities = 0
        configuration.in_configure_block = false
        assert_configuration_error(/[Mm]ax concurrent activities.*must be positive/)
      end

      it "raises ConfigurationError when max_concurrent_activities is negative" do
        configuration.in_configure_block = true
        configuration.max_concurrent_activities = -1
        configuration.in_configure_block = false
        assert_configuration_error(/[Mm]ax concurrent activities.*must be positive/)
      end

      it "accepts positive max_concurrent_activities" do
        configuration.in_configure_block = true
        configuration.max_concurrent_activities = 200
        configuration.in_configure_block = false
        configuration.validate!
      end

      it "raises ConfigurationError when max_concurrent_workflow_tasks is zero" do
        configuration.in_configure_block = true
        configuration.max_concurrent_workflow_tasks = 0
        configuration.in_configure_block = false
        assert_configuration_error(/[Mm]ax concurrent workflow.*must be positive/)
      end

      it "raises ConfigurationError when max_concurrent_workflow_tasks is negative" do
        configuration.in_configure_block = true
        configuration.max_concurrent_workflow_tasks = -5
        configuration.in_configure_block = false
        assert_configuration_error(/[Mm]ax concurrent workflow.*must be positive/)
      end

      it "accepts positive max_concurrent_workflow_tasks" do
        configuration.in_configure_block = true
        configuration.max_concurrent_workflow_tasks = 300
        configuration.in_configure_block = false
        configuration.validate!
      end

      it "accepts high concurrency values for both settings" do
        configuration.in_configure_block = true
        configuration.max_concurrent_activities = 500
        configuration.max_concurrent_workflow_tasks = 500
        configuration.in_configure_block = false
        configuration.validate!
      end
    end

    describe "with multiple validation failures" do
      it "collects and reports all validation errors" do
        configuration.in_configure_block = true
        configuration.target = "invalid"
        configuration.namespace = "has spaces"
        configuration.default_retry_backoff = 0.5
        configuration.max_payload_size_kb = -1
        configuration.in_configure_block = false

        error = assert_raises(ActiveJob::Temporal::ConfigurationError) { configuration.validate! }
        assert_includes error.message, "Configuration validation failed"
        assert_match(/[Tt]arget.*format/, error.message)
        assert_match(/[Nn]amespace.*contain only/, error.message)
        assert_match(/[Dd]efault retry backoff.*>= 1\.0/, error.message)
        assert_match(/[Mm]ax payload size.*positive|between/, error.message)
        assert_match(/\d+\.\s/, error.message)
      end

      it "shows single error without numbering" do
        configuration.in_configure_block = true
        configuration.target = "invalid"
        configuration.in_configure_block = false

        assert_configuration_error(/[Tt]arget.*format/)
      end
    end

    describe "with validation levels" do
      it "warns instead of raising when validation_level is warn" do
        warning_logger = warning_logger_recorder

        configuration.in_configure_block = true
        configuration.validation_level = :warn
        configuration.logger = warning_logger
        configuration.target = "invalid"
        configuration.in_configure_block = false

        configuration.validate!
        assert_equal 1, warning_logger.warnings.size
        assert_match(/[Tt]arget.*format/, warning_logger.warnings.first)
      end

      it "skips validation when validation_level is none" do
        warning_logger = warning_logger_recorder

        configuration.in_configure_block = true
        configuration.validation_level = :none
        configuration.logger = warning_logger
        configuration.target = nil
        configuration.default_retry_backoff = 0.5
        configuration.in_configure_block = false

        configuration.validate!
        assert_empty warning_logger.warnings
      end
    end
  end

  describe "Exception classes" do
    it "ConfigurationError inherits from Error" do
      assert_operator ActiveJob::Temporal::ConfigurationError, :<, ActiveJob::Temporal::Error
    end

    it "WorkflowNotFoundError inherits from Error" do
      assert_operator ActiveJob::Temporal::WorkflowNotFoundError, :<, ActiveJob::Temporal::Error
    end

    it "TemporalConnectionError inherits from Error" do
      assert_operator ActiveJob::Temporal::TemporalConnectionError, :<, ActiveJob::Temporal::Error
    end

    it "Error inherits from StandardError" do
      assert_operator ActiveJob::Temporal::Error, :<, StandardError
    end

    it "raises and catches ConfigurationError correctly" do
      error = assert_raises(ActiveJob::Temporal::ConfigurationError) do
        raise ActiveJob::Temporal::ConfigurationError, "test error"
      end
      assert_equal "test error", error.message
    end

    it "raises and catches WorkflowNotFoundError correctly" do
      error = assert_raises(ActiveJob::Temporal::WorkflowNotFoundError) do
        raise ActiveJob::Temporal::WorkflowNotFoundError, "workflow not found"
      end
      assert_equal "workflow not found", error.message
    end

    it "raises and catches TemporalConnectionError correctly" do
      error = assert_raises(ActiveJob::Temporal::TemporalConnectionError) do
        raise ActiveJob::Temporal::TemporalConnectionError, "connection failed"
      end
      assert_equal "connection failed", error.message
    end
  end

  def valid_encryption_key(label = "primary")
    Base64.strict_encode64(label.ljust(32, "-")[0, 32])
  end
end
