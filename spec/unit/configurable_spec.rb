# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal do
  before do
    described_class.instance_variable_set(:@config_mvar, nil)
  end

  describe ".config" do
    it "extends the configurable concern" do
      expect(described_class.singleton_class.ancestors).to include(ActiveJob::Temporal::Configurable)
    end

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

    it "clears block state when post-configuration validation fails" do
      expect do
        described_class.configure do |config|
          config.target = "invalid"
        end
      end.to raise_error(ActiveJob::Temporal::ConfigurationError)

      expect(described_class.config.in_configure_block).to be(false)
    end
  end

  describe ".validate!" do
    it "validates the module configuration" do
      described_class.configure do |config|
        config.target = "localhost:7233"
        config.namespace = "test"
      end

      expect { described_class.validate! }.not_to raise_error
    end

    it "raises ConfigurationError for invalid module configuration" do
      described_class.configure do |config|
        config.target = "localhost:7233"
        config.namespace = "test"
      end

      described_class.config.in_configure_block = true
      described_class.config.target = "invalid"
      described_class.config.in_configure_block = false

      expect { described_class.validate! }.to raise_error(
        ActiveJob::Temporal::ConfigurationError,
        /[Tt]arget must.*host:port/
      )
    end
  end

  describe "direct requires" do
    it "loads configuration with validation errors available" do
      command = [
        RbConfig.ruby,
        "-Ilib",
        "-e",
        <<~RUBY
          require "activejob/temporal/configuration"
          config = ActiveJob::Temporal::Configuration.new
          config.in_configure_block = true
          config.target = "invalid"
          config.in_configure_block = false
          begin
            config.validate!
          rescue ActiveJob::Temporal::ConfigurationError => error
            abort error.message unless error.message.match?(/[Tt]arget must.*host:port/)
          end
        RUBY
      ]

      expect(system(*command)).to be(true)
    end

    it "loads configurable independently after configuration" do
      command = [
        RbConfig.ruby,
        "-Ilib",
        "-e",
        <<~RUBY
          require "activejob/temporal/configurable"
          module ActiveJob
            module Temporal
              extend Configurable
            end
          end
          ActiveJob::Temporal.configure do |config|
            config.target = "localhost:7233"
            config.namespace = "test"
          end
          ActiveJob::Temporal.validate!
        RUBY
      ]

      expect(system(*command)).to be(true)
    end
  end

  describe "thread safety" do
    it "allows concurrent reads of configuration" do
      described_class.configure do |config|
        config.target = "localhost:7233"
        config.namespace = "test"
      end

      threads = 10.times.map do
        Thread.new do
          100.times do
            config = described_class.config
            expect(config.target).to eq("localhost:7233")
            expect(config.namespace).to eq("test")
          end
        end
      end

      threads.each(&:join)
    end

    it "synchronizes concurrent configuration modifications" do
      results = []
      mutex = Mutex.new

      threads = 5.times.map do |index|
        Thread.new do
          described_class.configure do |config|
            config.target = "localhost:#{7233 + index}"
            config.namespace = "test-#{index}"
            sleep 0.001
          end

          mutex.synchronize do
            results << {
              target: described_class.config.target,
              namespace: described_class.config.namespace
            }
          end
        end
      end

      threads.each(&:join)

      final_config = described_class.config
      expect(final_config.target).to match(/localhost:7\d{3}/)
      expect(final_config.namespace).to match(/test-\d/)

      case final_config.target
      when "localhost:7233"
        expect(final_config.namespace).to eq("test-0")
      when "localhost:7234"
        expect(final_config.namespace).to eq("test-1")
      when "localhost:7235"
        expect(final_config.namespace).to eq("test-2")
      when "localhost:7236"
        expect(final_config.namespace).to eq("test-3")
      when "localhost:7237"
        expect(final_config.namespace).to eq("test-4")
      end
    end

    it "ensures configure blocks have exclusive access" do
      described_class.configure do |config|
        config.target = "initial:7233"
        config.namespace = "initial"
      end

      access_log = []
      mutex = Mutex.new

      thread1 = Thread.new do
        described_class.configure do |config|
          mutex.synchronize { access_log << "thread1_start" }
          config.target = "thread1:7233"
          sleep 0.1
          config.namespace = "thread1"
          mutex.synchronize { access_log << "thread1_end" }
        end
      end

      sleep 0.01

      thread2 = Thread.new do
        described_class.configure do |config|
          mutex.synchronize { access_log << "thread2_start" }
          config.target = "thread2:7233"
          config.namespace = "thread2"
          mutex.synchronize { access_log << "thread2_end" }
        end
      end

      thread1.join
      thread2.join

      expect(access_log).to satisfy do |log|
        (log.index("thread1_end") < log.index("thread2_start")) ||
          (log.index("thread2_end") < log.index("thread1_start"))
      end
    end
  end
end
