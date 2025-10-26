# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal do
  before do
    described_class.instance_variable_set(:@config, nil)
  end

  describe ".config" do
    it "memoizes the configuration object" do
      expect(described_class.config).to be(described_class.config)
    end

    it "exposes the same instance via .configuration alias" do
      expect(described_class.config).to be(described_class.configuration)
    end
  end

  describe ".configure" do
    it "yields the configuration for mutation" do
      described_class.configure do |config|
        config.target = "localhost:7233"
        config.task_queue_prefix = "rails-"
      end

      expect(described_class.config.target).to eq("localhost:7233")
      expect(described_class.config.task_queue_prefix).to eq("rails-")
    end

    it "allows every attribute to be updated via the block" do
      custom_logger = double(:logger)

      described_class.configure do |config|
        config.target = "localhost:9000"
        config.namespace = "production"
        config.task_queue_prefix = "app-"
        config.default_activity_timeout = 10.minutes
        config.default_retry_initial_interval = 5.seconds
        config.default_retry_backoff = 3.0
        config.default_retry_max_attempts = 4
        config.logger = custom_logger
        config.enable_tracing = false
      end

      configured = described_class.config
      expect(configured.target).to eq("localhost:9000")
      expect(configured.namespace).to eq("production")
      expect(configured.task_queue_prefix).to eq("app-")
      expect(configured.default_activity_timeout).to eq(10.minutes)
      expect(configured.default_retry_initial_interval).to eq(5.seconds)
      expect(configured.default_retry_backoff).to eq(3.0)
      expect(configured.default_retry_max_attempts).to eq(4)
      expect(configured.logger).to be(custom_logger)
      expect(configured.enable_tracing).to be(false)
    end

    it "returns the configuration even when no block provided" do
      expect(described_class.configure).to be_a(ActiveJob::Temporal::Configuration)
    end
  end
end

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

  describe "#default_activity_timeout=" do
    it "accepts positive durations" do
      configuration.default_activity_timeout = 10.seconds
      expect(configuration.default_activity_timeout).to eq(10.seconds)
    end

    it "raises when duration is zero or negative" do
      expect { configuration.default_activity_timeout = 0 }.to raise_error(ArgumentError)
      expect { configuration.default_activity_timeout = -5 }.to raise_error(ArgumentError)
    end

    it "raises when value cannot be coerced into a duration" do
      expect { configuration.default_activity_timeout = Object.new }.to raise_error(ArgumentError)
    end
  end

  describe "#default_retry_initial_interval=" do
    it "accepts positive durations" do
      configuration.default_retry_initial_interval = 5.seconds
      expect(configuration.default_retry_initial_interval).to eq(5.seconds)
    end

    it "raises when duration is zero or negative" do
      expect { configuration.default_retry_initial_interval = 0.seconds }.to raise_error(ArgumentError)
    end

    it "raises when value lacks numeric semantics" do
      expect { configuration.default_retry_initial_interval = Object.new }.to raise_error(ArgumentError)
    end
  end
end
