# frozen_string_literal: true

require "spec_helper"

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

    it "uses the default workflow ID generator when none is configured" do
      expect(configuration.workflow_id_generator).to be_nil
    end
  end

  describe "environment variable support" do
    before do
      # Reset the memoized config to force new instance creation
      ActiveJob::Temporal.instance_variable_set(:@config, nil)
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

  describe "dynamic attribute methods" do
    it "raises NoMethodError for unknown attribute getter" do
      expect { configuration.unknown_attribute }
        .to raise_error(NoMethodError, /undefined method.*unknown_attribute/)
    end

    it "silently ignores unknown attribute setters" do
      # Unknown setters don't raise errors but also don't store the value
      expect { configuration.unknown_attribute = "value" }.not_to raise_error

      # Verify the value was not stored (getter still raises NoMethodError)
      expect { configuration.unknown_attribute }
        .to raise_error(NoMethodError, /undefined method.*unknown_attribute/)
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
end
