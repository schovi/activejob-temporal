# frozen_string_literal: true

require "spec_helper"
require "base64"
require "tmpdir"

RSpec.describe ActiveJob::Temporal::Configuration do
  subject(:configuration) { described_class.new }

  describe "defaults" do
    it "sets the Temporal endpoint" do
      expect(configuration.target).to eq("127.0.0.1:7233")
    end

    it "sets the namespace" do
      expect(configuration.namespace).to eq("default")
    end

    it "sets task queue prefix to nil" do
      expect(configuration.task_queue_prefix).to be_nil
    end

    it "configures activity timeout" do
      expect(configuration.default_activity_timeout).to eq(15.minutes)
    end

    it "configures retry initial interval" do
      expect(configuration.default_retry_initial_interval).to eq(30.seconds)
    end

    it "configures retry backoff" do
      expect(configuration.default_retry_backoff).to eq(2.0)
    end

    it "configures retry max attempts" do
      expect(configuration.default_retry_max_attempts).to eq(1)
    end

    it "enables tracing" do
      expect(configuration.enable_tracing).to be(true)
    end

    it "sets identity to nil by default" do
      expect(configuration.identity).to be_nil
    end

    it "sets max_concurrent_activities to 100" do
      expect(configuration.max_concurrent_activities).to eq(100)
    end

    it "sets max_concurrent_workflow_tasks to 5" do
      expect(configuration.max_concurrent_workflow_tasks).to eq(5)
    end

    it "sets task_queue to 'default'" do
      expect(configuration.task_queue).to eq("default")
    end

    it "sets TLS rotation defaults" do
      expect(configuration.tls).to be_nil
      expect(configuration.tls_cert_path).to be_nil
      expect(configuration.tls_key_path).to be_nil
      expect(configuration.tls_server_root_ca_cert_path).to be_nil
      expect(configuration.tls_domain).to be_nil
      expect(configuration.tls_cert_watch).to be(false)
      expect(configuration.tls_reload_signal).to eq("HUP")
    end

    it "sets priority task queue mappings to an empty hash" do
      expect(configuration.priority_task_queues).to eq({})
    end

    it "disables dead letter queue routing by default" do
      expect(configuration.dead_letter_queue).to be_nil
      expect(configuration.dead_letter_after_attempts).to be_nil
    end

    it "disables metrics by default" do
      expect(configuration.metrics_provider).to be(:none)
      expect(configuration.metrics_port).to be_nil
      expect(configuration.metrics_bind).to eq("127.0.0.1")
      expect(configuration.metrics_allow_public_bind).to be(false)
    end

    it "disables audit logging by default" do
      expect(configuration.audit_log).to be(false)
      expect(configuration.audit_logger).to be_nil
    end

    it "disables payload encryption by default" do
      expect(configuration.encrypt_payload).to be(false)
      expect(configuration.encryption_key).to be_nil
      expect(configuration.encryption_old_keys).to eq([])
    end

    it "uses JSON payload serialization by default" do
      expect(configuration.payload_serializer).to be(:json)
    end

    it "uses the default workflow ID generator when none is configured" do
      expect(configuration.workflow_id_generator).to be_nil
    end

    it "disables rate limiting by default" do
      expect(configuration.rate_limiter).to be_nil
      expect(configuration.global_rate_limit).to be_nil
    end

    it "sets an empty middleware chain" do
      expect(configuration.middleware_chain).to be_a(ActiveJob::Temporal::Middleware::Chain)
      expect(configuration.middleware_chain.to_a).to be_empty
    end

    it "uses strict validation by default" do
      expect(configuration.validation_level).to be(:strict)
    end
  end

  describe "environment variable support" do
    before do
      ActiveJob::Temporal.instance_variable_set(:@config_mvar, nil)
    end

    it "reads target from ACTIVEJOB_TEMPORAL_TARGET environment variable" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TARGET").and_return("custom:9999")

      config = described_class.new
      expect(config.target).to eq("custom:9999")
    end

    it "uses default target when ACTIVEJOB_TEMPORAL_TARGET is not set" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TARGET").and_return(nil)

      config = described_class.new
      expect(config.target).to eq("127.0.0.1:7233")
    end

    it "reads namespace from ACTIVEJOB_TEMPORAL_NAMESPACE environment variable" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_NAMESPACE").and_return("production")

      config = described_class.new
      expect(config.namespace).to eq("production")
    end

    it "uses default namespace when ACTIVEJOB_TEMPORAL_NAMESPACE is not set" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_NAMESPACE").and_return(nil)

      config = described_class.new
      expect(config.namespace).to eq("default")
    end

    it "reads task_queue_prefix from ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX environment variable" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX").and_return("my-app-")

      config = described_class.new
      expect(config.task_queue_prefix).to eq("my-app-")
    end

    it "uses default task_queue_prefix (nil) when ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX is not set" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX").and_return(nil)

      config = described_class.new
      expect(config.task_queue_prefix).to be_nil
    end

    it "reads task_queue from ACTIVEJOB_TEMPORAL_TASK_QUEUE environment variable" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TASK_QUEUE").and_return("critical")

      config = described_class.new
      expect(config.task_queue).to eq("critical")
    end

    it "uses default task_queue ('default') when ACTIVEJOB_TEMPORAL_TASK_QUEUE is not set" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TASK_QUEUE").and_return(nil)

      config = described_class.new
      expect(config.task_queue).to eq("default")
    end

    it "reads max_payload_size_kb from ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB and converts to integer" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB").and_return("512")

      config = described_class.new
      expect(config.max_payload_size_kb).to eq(512)
    end

    it "reads payload serializer from ACTIVEJOB_TEMPORAL_PAYLOAD_SERIALIZER" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_PAYLOAD_SERIALIZER").and_return("message_pack")

      config = described_class.new
      expect(config.payload_serializer).to be(:message_pack)
    end

    it "uses default max_payload_size_kb when ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB is not set" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB").and_return(nil)

      config = described_class.new
      expect(config.max_payload_size_kb).to eq(250)
    end

    it "handles multiple environment variables set simultaneously" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TARGET").and_return("temporal.prod:7233")
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_NAMESPACE").and_return("production")
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TASK_QUEUE_PREFIX").and_return("app-")
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_MAX_PAYLOAD_SIZE_KB").and_return("1024")

      config = described_class.new
      expect(config.target).to eq("temporal.prod:7233")
      expect(config.namespace).to eq("production")
      expect(config.task_queue_prefix).to eq("app-")
      expect(config.max_payload_size_kb).to eq(1024)
    end

    it "allows explicit configuration to override environment variables" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TARGET").and_return("env-target:7233")

      config = described_class.new
      config.target = "explicit-target:8888"

      expect(config.target).to eq("explicit-target:8888")
    end

    it "validates environment variable values when validate! is called" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TARGET").and_return("invalid-format")

      config = described_class.new
      expect { config.validate! }.to raise_error(
        ActiveJob::Temporal::ConfigurationError,
        /[Tt]arget must.*host:port/
      )
    end

    it "reads max_concurrent_activities from ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES and converts to integer" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES").and_return("200")

      config = described_class.new
      expect(config.max_concurrent_activities).to eq(200)
    end

    it "uses default max_concurrent_activities when ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES is not set" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_ACTIVITIES").and_return(nil)

      config = described_class.new
      expect(config.max_concurrent_activities).to eq(100)
    end

    it "reads max_concurrent_workflow_tasks from ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS env var" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS").and_return("300")

      config = described_class.new
      expect(config.max_concurrent_workflow_tasks).to eq(300)
    end

    it "reads metrics provider from ACTIVEJOB_TEMPORAL_METRICS_PROVIDER" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_METRICS_PROVIDER").and_return("prometheus")

      config = described_class.new
      expect(config.metrics_provider).to be(:prometheus)
    end

    it "reads metrics port from ACTIVEJOB_TEMPORAL_METRICS_PORT and converts to integer" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_METRICS_PORT").and_return("9394")

      config = described_class.new
      expect(config.metrics_port).to eq(9394)
    end

    it "reads metrics bind address from ACTIVEJOB_TEMPORAL_METRICS_BIND" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_METRICS_BIND").and_return("0.0.0.0")

      config = described_class.new
      expect(config.metrics_bind).to eq("0.0.0.0")
    end

    it "reads metrics public bind opt-in from ACTIVEJOB_TEMPORAL_METRICS_ALLOW_PUBLIC_BIND" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_METRICS_ALLOW_PUBLIC_BIND").and_return("true")

      config = described_class.new
      expect(config.metrics_allow_public_bind).to be(true)
    end

    it "reads dead letter queue settings from environment variables" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_DEAD_LETTER_QUEUE").and_return("failed_jobs")
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_DEAD_LETTER_AFTER_ATTEMPTS").and_return("3")

      config = described_class.new
      expect(config.dead_letter_queue).to eq("failed_jobs")
      expect(config.dead_letter_after_attempts).to eq(3)
    end

    it "reads audit logging from ACTIVEJOB_TEMPORAL_AUDIT_LOG" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_AUDIT_LOG").and_return("true")

      config = described_class.new
      expect(config.audit_log).to be(true)
    end

    it "reads payload encryption from ACTIVEJOB_TEMPORAL_ENCRYPT_PAYLOAD" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_ENCRYPT_PAYLOAD").and_return("true")

      config = described_class.new
      expect(config.encrypt_payload).to be(true)
    end

    it "reads encryption key from ACTIVEJOB_TEMPORAL_ENCRYPTION_KEY" do
      key = valid_encryption_key
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_ENCRYPTION_KEY").and_return(key)

      config = described_class.new
      expect(config.encryption_key).to eq(key)
    end

    it "reads TLS certificate paths from environment variables" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TLS_CERT_PATH").and_return("/certs/client.pem")
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TLS_KEY_PATH").and_return("/certs/client-key.pem")
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TLS_SERVER_ROOT_CA_CERT_PATH").and_return("/certs/ca.pem")
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TLS_DOMAIN").and_return("temporal.example.dev")

      config = described_class.new
      expect(config.tls_cert_path).to eq("/certs/client.pem")
      expect(config.tls_key_path).to eq("/certs/client-key.pem")
      expect(config.tls_server_root_ca_cert_path).to eq("/certs/ca.pem")
      expect(config.tls_domain).to eq("temporal.example.dev")
    end

    it "reads TLS reload controls from environment variables" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TLS_CERT_WATCH").and_return("true")
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_TLS_RELOAD_SIGNAL").and_return("USR1")

      config = described_class.new
      expect(config.tls_cert_watch).to be(true)
      expect(config.tls_reload_signal).to eq("USR1")
    end

    it "uses default (5) when ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS is not set" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("ACTIVEJOB_TEMPORAL_MAX_CONCURRENT_WORKFLOW_TASKS").and_return(nil)

      config = described_class.new
      expect(config.max_concurrent_workflow_tasks).to eq(5)
    end
  end

  describe "#logger" do
    it "falls back to a standard logger when Rails is unavailable" do
      expect(configuration.logger).to be_a(Logger)
    end

    it "uses Rails.logger when Rails responds to logger" do
      rails_logger = instance_double(Logger)
      stub_const("Rails", Class.new do
        class << self
          attr_accessor :logger
        end
      end)
      Rails.logger = rails_logger

      expect(described_class.new.logger).to be(rails_logger)
    end
  end

  describe "#task_queue_prefix=" do
    it "accepts nil values" do
      configuration.task_queue_prefix = nil
      expect(configuration.task_queue_prefix).to be_nil
    end
  end

  describe "#priority_task_queues=" do
    it "accepts priority to task queue mappings" do
      configuration.priority_task_queues = { 10 => "high_priority", 90 => "low_priority" }

      expect(configuration.priority_task_queues).to eq(10 => "high_priority", 90 => "low_priority")
    end

    it "rejects non-hash values" do
      expect { configuration.priority_task_queues = "high_priority" }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Priority task queues must be a hash/)
    end

    it "rejects non-integer priority keys" do
      expect { configuration.priority_task_queues = { high: "high_priority" } }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /priority keys must be integers/)
    end

    it "rejects blank task queue names" do
      expect { configuration.priority_task_queues = { 10 => " " } }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /task queue names must be present/)
    end
  end

  describe "#dead_letter_queue=" do
    it "accepts nil and non-blank task queue names" do
      configuration.dead_letter_queue = "failed_jobs"
      expect(configuration.dead_letter_queue).to eq("failed_jobs")

      configuration.dead_letter_queue = nil
      expect(configuration.dead_letter_queue).to be_nil
    end

    it "rejects blank task queue names" do
      expect { configuration.dead_letter_queue = " " }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Dead letter queue must be present/)
    end
  end

  describe "#dead_letter_after_attempts=" do
    it "accepts nil and positive integer thresholds" do
      configuration.dead_letter_queue = "failed_jobs"
      configuration.dead_letter_after_attempts = 3
      expect(configuration.dead_letter_after_attempts).to eq(3)

      configuration.dead_letter_after_attempts = nil
      expect(configuration.dead_letter_after_attempts).to be_nil
    end

    it "rejects zero and negative thresholds" do
      configuration.dead_letter_queue = "failed_jobs"

      expect { configuration.dead_letter_after_attempts = 0 }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Dead letter after attempts must be greater than 0/)

      expect { configuration.dead_letter_after_attempts = -1 }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Dead letter after attempts must be greater than 0/)
    end

    it "requires a dead letter queue when a threshold is configured" do
      expect { configuration.dead_letter_after_attempts = 3 }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /requires dead_letter_queue/)
    end
  end

  describe "#metrics_provider=" do
    it "accepts prometheus and none" do
      configuration.metrics_provider = :prometheus
      expect(configuration.metrics_provider).to be(:prometheus)

      configuration.metrics_provider = :none
      expect(configuration.metrics_provider).to be(:none)
    end

    it "rejects unsupported providers" do
      expect { configuration.metrics_provider = :statsd }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Metrics provider must be one of/)
    end
  end

  describe "#metrics_port=" do
    it "accepts nil and valid TCP ports" do
      configuration.metrics_port = nil
      expect(configuration.metrics_port).to be_nil

      configuration.metrics_port = 9394
      expect(configuration.metrics_port).to eq(9394)
    end

    it "rejects invalid ports" do
      expect { configuration.metrics_port = 70_000 }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Metrics port must be between 1 and 65535/)
    end
  end

  describe "#metrics_allow_public_bind=" do
    it "accepts boolean values" do
      configuration.metrics_allow_public_bind = true
      expect(configuration.metrics_allow_public_bind).to be(true)

      configuration.metrics_allow_public_bind = false
      expect(configuration.metrics_allow_public_bind).to be(false)
    end

    it "rejects non-boolean values" do
      expect { configuration.metrics_allow_public_bind = "true" }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Metrics allow public bind must be true or false/)
    end
  end

  describe "#audit_log=" do
    it "accepts boolean values" do
      configuration.audit_log = true
      expect(configuration.audit_log).to be(true)

      configuration.audit_log = false
      expect(configuration.audit_log).to be(false)
    end

    it "rejects non-boolean values" do
      expect { configuration.audit_log = "true" }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Audit log must be true or false/)
    end
  end

  describe "#audit_logger=" do
    it "accepts nil and logger-compatible values" do
      logger = Logger.new(StringIO.new)

      configuration.audit_logger = logger
      expect(configuration.audit_logger).to be(logger)

      configuration.audit_logger = nil
      expect(configuration.audit_logger).to be_nil
    end

    it "rejects values that cannot receive info logs" do
      expect { configuration.audit_logger = Object.new }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Audit logger must respond to #info/)
    end
  end

  describe "#encrypt_payload=" do
    it "accepts boolean values when encryption key configuration is valid" do
      configuration.encryption_key = valid_encryption_key

      configuration.encrypt_payload = true
      expect(configuration.encrypt_payload).to be(true)

      configuration.encrypt_payload = false
      expect(configuration.encrypt_payload).to be(false)
    end

    it "rejects non-boolean values" do
      expect { configuration.encrypt_payload = "true" }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Encrypt payload must be true or false/)
    end

    it "requires a primary encryption key when enabled" do
      expect { configuration.encrypt_payload = true }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Encryption key is required/)
    end
  end

  describe "#encryption_key=" do
    it "accepts nil and Base64-encoded 32-byte keys" do
      configuration.encryption_key = valid_encryption_key
      expect(configuration.encryption_key).to eq(valid_encryption_key)

      configuration.encryption_key = nil
      expect(configuration.encryption_key).to be_nil
    end

    it "accepts key metadata with an explicit id" do
      key_metadata = { id: "2026-05", key: valid_encryption_key }

      configuration.encryption_key = key_metadata

      expect(configuration.encryption_key).to eq(key_metadata)
    end

    it "rejects keys that are not valid Base64" do
      expect { configuration.encryption_key = "not base64" }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Encryption key must be a Base64-encoded 32-byte/)
    end

    it "rejects key metadata with unsafe ids" do
      expect { configuration.encryption_key = { id: "bad key", key: valid_encryption_key } }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Encryption key must be a Base64-encoded 32-byte/)
    end

    it "rejects Base64 keys with the wrong decoded length" do
      short_key = Base64.strict_encode64("short")

      expect { configuration.encryption_key = short_key }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Encryption key must be a Base64-encoded 32-byte/)
    end
  end

  describe "#encryption_old_keys=" do
    it "accepts an array of Base64-encoded 32-byte keys" do
      old_keys = [valid_encryption_key("old-1"), valid_encryption_key("old-2")]

      configuration.encryption_old_keys = old_keys

      expect(configuration.encryption_old_keys).to eq(old_keys)
    end

    it "accepts old key metadata with explicit ids" do
      old_keys = [
        { id: "2026-01", key: valid_encryption_key("old-1") },
        { id: "2026-02", key: valid_encryption_key("old-2"), decrypt_until: Time.utc(2027, 1, 1) }
      ]

      configuration.encryption_old_keys = old_keys

      expect(configuration.encryption_old_keys).to eq(old_keys)
    end

    it "rejects non-array values" do
      expect { configuration.encryption_old_keys = valid_encryption_key }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Encryption old keys must be an array/)
    end

    it "rejects arrays containing invalid keys" do
      expect { configuration.encryption_old_keys = [valid_encryption_key, "invalid"] }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Encryption old keys must contain only/)
    end
  end

  describe "#payload_serializer=" do
    it "accepts built-in payload serializers" do
      configuration.payload_serializer = :message_pack
      expect(configuration.payload_serializer).to be(:message_pack)

      configuration.payload_serializer = :msgpack
      expect(configuration.payload_serializer).to be(:msgpack)

      configuration.payload_serializer = :marshal
      expect(configuration.payload_serializer).to be(:marshal)

      configuration.payload_serializer = :json
      expect(configuration.payload_serializer).to be(:json)
    end

    it "rejects unsupported payload serializers" do
      expect { configuration.payload_serializer = :yaml }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Payload serializer is not supported/)
    end
  end

  describe "#workflow_id_generator=" do
    it "accepts callable values" do
      generator = ->(job) { "custom:#{job.job_id}" }

      configuration.workflow_id_generator = generator

      expect(configuration.workflow_id_generator).to be(generator)
    end

    it "accepts nil values" do
      configuration.workflow_id_generator = nil

      expect(configuration.workflow_id_generator).to be_nil
    end

    it "rejects non-callable values" do
      expect { configuration.workflow_id_generator = "custom-id" }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Workflow id generator must respond to #call/)
    end

    it "rejects callables that cannot accept a job argument" do
      expect { configuration.workflow_id_generator = -> { "custom-id" } }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /must accept one ActiveJob argument/)
    end
  end

  describe "#rate_limiter=" do
    it "accepts nil and limiter backends" do
      limiter = instance_double("RateLimiter", wait_time_for: 0)

      configuration.rate_limiter = limiter
      expect(configuration.rate_limiter).to be(limiter)

      configuration.rate_limiter = nil
      expect(configuration.rate_limiter).to be_nil
    end

    it "accepts callable limiter backends" do
      limiter = ->(_rate_limits) { 0 }

      configuration.rate_limiter = limiter

      expect(configuration.rate_limiter).to be(limiter)
    end

    it "rejects unsupported limiter backends" do
      expect { configuration.rate_limiter = Object.new }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Rate limiter must respond to #wait_time_for or #call/)
    end

    it "rejects limiter backends that do not accept rate limits" do
      expect { configuration.rate_limiter = -> { 0 } }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Rate limiter must accept one rate_limits argument/)
    end
  end

  describe "#global_rate_limit=" do
    it "accepts normalized global rate limit hashes when a limiter is configured" do
      configuration.rate_limiter = ->(_rate_limits) { 0 }

      configuration.global_rate_limit = { limit: 100, per: :second }

      expect(configuration.global_rate_limit).to eq(limit: 100, per: :second)
    end

    it "requires a limiter backend" do
      expect { configuration.global_rate_limit = { limit: 100, per: :second } }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Global rate limit requires rate_limiter/)
    end

    it "rejects invalid global rate limit hashes" do
      configuration.rate_limiter = ->(_rate_limits) { 0 }

      expect { configuration.global_rate_limit = { limit: 0, per: :second } }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Global rate limit must be a hash/)
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

      expect(configuration.middleware_chain.to_a).to eq([registered])
      expect(configuration.middleware_chain.call(:job) { events << :perform }).to eq(%i[before perform after])
    end

    it "rejects invalid middleware chain replacements" do
      expect { configuration.middleware_chain = Object.new }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Middleware chain must respond to #add and #call/)
    end
  end

  describe "#validation_level=" do
    it "accepts supported validation levels" do
      configuration.validation_level = :warn
      expect(configuration.validation_level).to be(:warn)

      configuration.validation_level = :none
      expect(configuration.validation_level).to be(:none)
    end

    it "rejects unsupported validation levels" do
      expect { configuration.validation_level = :relaxed }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /Validation level must be one of/)
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

        expect { configuration.validate! }.not_to raise_error
      end
    end

    it "rejects a client certificate path without a matching key path" do
      with_tls_files do |cert_path, _key_path, _root_ca_path|
        expect { configuration.tls_cert_path = cert_path }
          .to raise_error(ActiveJob::Temporal::ConfigurationError, /requires tls_key_path/)
      end
    end

    it "rejects unreadable TLS paths" do
      missing_path = File.join(Dir.tmpdir, "missing-root-ca.pem")

      expect { configuration.tls_server_root_ca_cert_path = missing_path }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /readable, non-symlink file/)
    end

    it "rejects symlink TLS paths" do
      with_tls_files do |cert_path, key_path, _root_ca_path|
        symlink_path = "#{cert_path}.link"
        File.symlink(cert_path, symlink_path)
        configuration.in_configure_block = true
        configuration.tls_cert_path = symlink_path
        configuration.tls_key_path = key_path
        configuration.in_configure_block = false

        expect { configuration.validate! }
          .to raise_error(ActiveJob::Temporal::ConfigurationError, /readable, non-symlink file/)
      end
    end

    it "rejects certificate watching when no TLS file paths are configured" do
      expect { configuration.tls_cert_watch = true }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /requires at least one TLS certificate path/)
    end

    it "rejects non-boolean certificate watching values" do
      expect { configuration.tls_cert_watch = "true" }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /must be true or false/)
    end

    it "rejects blank TLS domain overrides" do
      expect { configuration.tls_domain = " " }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /must be present/)
    end

    it "accepts trappable TLS reload signal names" do
      configuration.tls_reload_signal = "SIGHUP"

      expect(configuration.tls_reload_signal).to eq("SIGHUP")
    end

    it "rejects invalid or reserved TLS reload signal names" do
      %w[HUP! HUP123 9 CHLD INT KILL PIPE QUIT STOP TERM].each do |signal_name|
        expect { configuration.tls_reload_signal = signal_name }
          .to raise_error(ActiveJob::Temporal::ConfigurationError, /must be a signal name/)
      end
    end
  end

  describe "configuration attribute methods" do
    it "defines getter and setter methods for every configuration attribute" do
      explicit_methods = described_class.instance_methods(false)

      ActiveJob::Temporal::CONFIGURATION_ATTRIBUTES.each_key do |attribute|
        expect(explicit_methods).to include(attribute)
        expect(explicit_methods).to include(:"#{attribute}=")
      end
    end

    it "does not define dynamic dispatch hooks for configuration attributes" do
      explicit_methods = described_class.instance_methods(false)

      expect(explicit_methods).not_to include(:method_missing)
      expect(explicit_methods).not_to include(:respond_to_missing?)
    end

    it "raises NoMethodError for unknown attribute getter" do
      expect { configuration.unknown_attribute }
        .to raise_error(NoMethodError, /undefined method.*unknown_attribute/)
    end

    it "raises NoMethodError for unknown attribute setter" do
      expect { configuration.unknown_attribute = "value" }
        .to raise_error(NoMethodError, /undefined method.*unknown_attribute=/)
    end

    it "returns false for respond_to? with unknown attribute" do
      expect(configuration.respond_to?(:unknown_attribute)).to be(false)
      expect(configuration.respond_to?(:unknown_attribute=)).to be(false)
    end

    it "returns true for respond_to? with known attributes" do
      expect(configuration.respond_to?(:target)).to be(true)
      expect(configuration.respond_to?(:target=)).to be(true)
      expect(configuration.respond_to?(:namespace)).to be(true)
      expect(configuration.respond_to?(:namespace=)).to be(true)
    end
  end

  describe "#default_activity_timeout=" do
    it "accepts positive durations" do
      configuration.default_activity_timeout = 10.seconds
      expect(configuration.default_activity_timeout).to eq(10.seconds)
    end

    it "raises when duration is zero or negative" do
      expect { configuration.default_activity_timeout = 0 }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /must be positive/)
      expect { configuration.default_activity_timeout = -5 }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /must be positive/)
    end

    it "raises when value cannot be coerced into a duration" do
      expect { configuration.default_activity_timeout = Object.new }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /must be a duration/)
    end
  end

  describe "#default_retry_initial_interval=" do
    it "accepts positive durations" do
      configuration.default_retry_initial_interval = 5.seconds
      expect(configuration.default_retry_initial_interval).to eq(5.seconds)
    end

    it "raises when duration is zero or negative" do
      expect { configuration.default_retry_initial_interval = 0.seconds }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /must be positive/)
    end

    it "raises when value lacks numeric semantics" do
      expect { configuration.default_retry_initial_interval = Object.new }
        .to raise_error(ActiveJob::Temporal::ConfigurationError, /must be a duration/)
    end
  end

  describe "#validate!" do
    context "with valid configuration" do
      it "does not raise any errors with default values" do
        expect { configuration.validate! }.not_to raise_error
      end

      it "does not raise errors with all valid custom values" do
        configuration.target = "temporal.example.com:7233"
        configuration.namespace = "production-namespace"
        configuration.default_activity_timeout = 10.minutes
        configuration.default_retry_initial_interval = 5.seconds
        configuration.default_retry_backoff = 2.5
        configuration.default_retry_max_attempts = 5
        configuration.max_payload_size_kb = 500

        expect { configuration.validate! }.not_to raise_error
      end
    end

    context "when target is invalid" do
      it "raises ConfigurationError for missing port" do
        configuration.in_configure_block = true
        configuration.target = "localhost"
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Tt]arget must.*host:port/
        )
      end

      it "raises ConfigurationError for missing host" do
        configuration.in_configure_block = true
        configuration.target = ":7233"
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Tt]arget must.*host:port/
        )
      end

      it "raises ConfigurationError for invalid format" do
        configuration.in_configure_block = true
        configuration.target = "badformat"
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Tt]arget must.*host:port/
        )
      end

      it "raises ConfigurationError for port number too long" do
        configuration.in_configure_block = true
        configuration.target = "localhost:123456"
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Tt]arget must.*host:port/
        )
      end

      it "raises ConfigurationError for invalid characters" do
        configuration.in_configure_block = true
        configuration.target = "host with spaces:7233"
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Tt]arget must.*host:port/
        )
      end

      it "raises ConfigurationError when target is nil" do
        configuration.in_configure_block = true
        configuration.target = nil
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /Target host is required|Target must be in format/
        )
      end
    end

    context "when namespace is invalid" do
      it "raises ConfigurationError for spaces in namespace" do
        configuration.in_configure_block = true
        configuration.namespace = "has spaces"
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Nn]amespace must contain only/
        )
      end

      it "raises ConfigurationError for special characters" do
        configuration.in_configure_block = true
        configuration.namespace = "special!chars"
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Nn]amespace must contain only/
        )
      end

      it "raises ConfigurationError for dots in namespace" do
        configuration.in_configure_block = true
        configuration.namespace = "namespace.with.dots"
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Nn]amespace must contain only/
        )
      end

      it "raises ConfigurationError when namespace is nil" do
        configuration.in_configure_block = true
        configuration.namespace = nil
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /Namespace is required|namespace must contain only alphanumeric/
        )
      end

      it "accepts valid namespace with hyphens and underscores" do
        configuration.in_configure_block = true
        configuration.namespace = "valid-namespace_123"
        configuration.in_configure_block = false
        expect { configuration.validate! }.not_to raise_error
      end
    end

    context "when timeouts are invalid" do
      it "raises ConfigurationError when default_activity_timeout is zero" do
        configuration.in_configure_block = true
        configuration[:default_activity_timeout] = 0
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Dd]efault activity timeout.*must be positive/
        )
      end

      it "raises ConfigurationError when default_activity_timeout is negative" do
        configuration.in_configure_block = true
        configuration[:default_activity_timeout] = -5
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Dd]efault activity timeout.*must be positive/
        )
      end

      it "raises ConfigurationError when default_retry_initial_interval is zero" do
        configuration.in_configure_block = true
        configuration[:default_retry_initial_interval] = 0.seconds
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Dd]efault retry initial interval.*must be positive/
        )
      end

      it "raises ConfigurationError when default_retry_initial_interval is negative" do
        configuration.in_configure_block = true
        configuration[:default_retry_initial_interval] = -10
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Dd]efault retry initial interval.*must be positive/
        )
      end

      it "raises ConfigurationError when timeout is not a duration" do
        configuration.in_configure_block = true
        configuration[:default_activity_timeout] = "not a duration"
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Dd]efault activity timeout.*must be a duration/
        )
      end
    end

    context "when retry settings are invalid" do
      it "raises ConfigurationError when backoff is less than 1.0" do
        configuration.in_configure_block = true
        configuration.default_retry_backoff = 0.5
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Dd]efault retry backoff.*>= 1\.0/
        )
      end

      it "raises ConfigurationError when backoff is zero" do
        configuration.in_configure_block = true
        configuration.default_retry_backoff = 0.0
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Dd]efault retry backoff.*>= 1\.0/
        )
      end

      it "raises ConfigurationError when backoff is negative" do
        configuration.in_configure_block = true
        configuration.default_retry_backoff = -1.0
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Dd]efault retry backoff.*>= 1\.0/
        )
      end

      it "accepts backoff exactly equal to 1.0" do
        configuration.in_configure_block = true
        configuration.default_retry_backoff = 1.0
        configuration.in_configure_block = false
        expect { configuration.validate! }.not_to raise_error
      end

      it "raises ConfigurationError when max_attempts is negative" do
        configuration.in_configure_block = true
        configuration.default_retry_max_attempts = -1
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Dd]efault retry max attempts.*>= 0/
        )
      end

      it "accepts max_attempts equal to zero" do
        configuration.in_configure_block = true
        configuration.default_retry_max_attempts = 0
        configuration.in_configure_block = false
        expect { configuration.validate! }.not_to raise_error
      end
    end

    context "when payload size is invalid" do
      it "raises ConfigurationError when exceeding maximum limit" do
        configuration.in_configure_block = true
        configuration.max_payload_size_kb = 2_097_153
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Mm]ax payload size.*2,097,152/
        )
      end

      it "raises ConfigurationError when far exceeding maximum limit" do
        configuration.in_configure_block = true
        configuration.max_payload_size_kb = 5_000_000
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Mm]ax payload size.*2,097,152/
        )
      end

      it "accepts payload size at the maximum limit" do
        configuration.in_configure_block = true
        configuration.max_payload_size_kb = 2_097_152
        configuration.in_configure_block = false
        expect { configuration.validate! }.not_to raise_error
      end

      it "raises ConfigurationError when payload size is zero" do
        configuration.in_configure_block = true
        configuration.max_payload_size_kb = 0
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Mm]ax payload size.*(must be positive|between 1)/
        )
      end

      it "raises ConfigurationError when payload size is negative" do
        configuration.in_configure_block = true
        configuration.max_payload_size_kb = -100
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Mm]ax payload size.*(must be positive|between 1)/
        )
      end

      it "accepts a reasonable payload size" do
        configuration.in_configure_block = true
        configuration.max_payload_size_kb = 1024
        configuration.in_configure_block = false
        expect { configuration.validate! }.not_to raise_error
      end
    end

    context "when worker concurrency settings are invalid" do
      it "raises ConfigurationError when max_concurrent_activities is zero" do
        configuration.in_configure_block = true
        configuration.max_concurrent_activities = 0
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Mm]ax concurrent activities.*must be positive/
        )
      end

      it "raises ConfigurationError when max_concurrent_activities is negative" do
        configuration.in_configure_block = true
        configuration.max_concurrent_activities = -1
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Mm]ax concurrent activities.*must be positive/
        )
      end

      it "accepts positive max_concurrent_activities" do
        configuration.in_configure_block = true
        configuration.max_concurrent_activities = 200
        configuration.in_configure_block = false
        expect { configuration.validate! }.not_to raise_error
      end

      it "raises ConfigurationError when max_concurrent_workflow_tasks is zero" do
        configuration.in_configure_block = true
        configuration.max_concurrent_workflow_tasks = 0
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Mm]ax concurrent workflow.*must be positive/
        )
      end

      it "raises ConfigurationError when max_concurrent_workflow_tasks is negative" do
        configuration.in_configure_block = true
        configuration.max_concurrent_workflow_tasks = -5
        configuration.in_configure_block = false
        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Mm]ax concurrent workflow.*must be positive/
        )
      end

      it "accepts positive max_concurrent_workflow_tasks" do
        configuration.in_configure_block = true
        configuration.max_concurrent_workflow_tasks = 300
        configuration.in_configure_block = false
        expect { configuration.validate! }.not_to raise_error
      end

      it "accepts high concurrency values for both settings" do
        configuration.in_configure_block = true
        configuration.max_concurrent_activities = 500
        configuration.max_concurrent_workflow_tasks = 500
        configuration.in_configure_block = false
        expect { configuration.validate! }.not_to raise_error
      end
    end

    context "with multiple validation failures" do
      it "collects and reports all validation errors" do
        configuration.in_configure_block = true
        configuration.target = "invalid"
        configuration.namespace = "has spaces"
        configuration.default_retry_backoff = 0.5
        configuration.max_payload_size_kb = -1
        configuration.in_configure_block = false

        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError
        ) do |error|
          # Should include header for multiple errors
          expect(error.message).to include("Configuration validation failed")

          # Should include all errors (with flexible matching for case and formatting)
          expect(error.message).to match(/[Tt]arget.*format/)
          expect(error.message).to match(/[Nn]amespace.*contain only/)
          expect(error.message).to match(/[Dd]efault retry backoff.*>= 1\.0/)
          expect(error.message).to match(/[Mm]ax payload size.*positive|between/)

          # Should number the errors
          expect(error.message).to match(/\d+\.\s/)
        end
      end

      it "shows single error without numbering" do
        configuration.in_configure_block = true
        configuration.target = "invalid"
        configuration.in_configure_block = false

        expect { configuration.validate! }.to raise_error(
          ActiveJob::Temporal::ConfigurationError,
          /[Tt]arget.*format/ # Should start with the error (not "Configuration validation failed")
        )
      end
    end

    context "with validation levels" do
      it "warns instead of raising when validation_level is warn" do
        warning_logger = instance_spy(Logger)

        configuration.in_configure_block = true
        configuration.validation_level = :warn
        configuration.logger = warning_logger
        configuration.target = "invalid"
        configuration.in_configure_block = false

        expect { configuration.validate! }.not_to raise_error
        expect(warning_logger).to have_received(:warn).with(/[Tt]arget.*format/)
      end

      it "skips validation when validation_level is none" do
        warning_logger = instance_spy(Logger)

        configuration.in_configure_block = true
        configuration.validation_level = :none
        configuration.logger = warning_logger
        configuration.target = nil
        configuration.default_retry_backoff = 0.5
        configuration.in_configure_block = false

        expect { configuration.validate! }.not_to raise_error
        expect(warning_logger).not_to have_received(:warn)
      end
    end
  end

  describe "Exception classes" do
    it "ConfigurationError inherits from Error" do
      expect(ActiveJob::Temporal::ConfigurationError).to be < ActiveJob::Temporal::Error
    end

    it "WorkflowNotFoundError inherits from Error" do
      expect(ActiveJob::Temporal::WorkflowNotFoundError).to be < ActiveJob::Temporal::Error
    end

    it "TemporalConnectionError inherits from Error" do
      expect(ActiveJob::Temporal::TemporalConnectionError).to be < ActiveJob::Temporal::Error
    end

    it "Error inherits from StandardError" do
      expect(ActiveJob::Temporal::Error).to be < StandardError
    end

    it "raises and catches ConfigurationError correctly" do
      expect do
        raise ActiveJob::Temporal::ConfigurationError, "test error"
      end.to raise_error(ActiveJob::Temporal::ConfigurationError, "test error")
    end

    it "raises and catches WorkflowNotFoundError correctly" do
      expect do
        raise ActiveJob::Temporal::WorkflowNotFoundError, "workflow not found"
      end.to raise_error(ActiveJob::Temporal::WorkflowNotFoundError, "workflow not found")
    end

    it "raises and catches TemporalConnectionError correctly" do
      expect do
        raise ActiveJob::Temporal::TemporalConnectionError, "connection failed"
      end.to raise_error(ActiveJob::Temporal::TemporalConnectionError, "connection failed")
    end
  end

  def valid_encryption_key(label = "primary")
    Base64.strict_encode64(label.ljust(32, "-")[0, 32])
  end
end
