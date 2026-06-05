# frozen_string_literal: true

require "spec_helper"

describe ActiveJob::Temporal do
  before do
    described_class.instance_variable_set(:@config_mvar, nil)
  end

  after do
    described_class.instance_variable_set(:@config_mvar, nil)
  end

  describe ".config" do
    it "extends the configurable concern" do
      assert_includes described_class.singleton_class.ancestors, ActiveJob::Temporal::Configurable
    end

    it "memoizes the configuration object" do
      assert_same described_class.config, described_class.config
    end

    it "exposes the same instance via .configuration alias" do
      assert_same described_class.config, described_class.configuration
    end
  end

  describe ".configure" do
    it "yields the configuration for mutation" do
      described_class.configure do |config|
        config.target = "localhost:7233"
        config.task_queue_prefix = "rails-"
      end

      assert_equal "localhost:7233", described_class.config.target
      assert_equal "rails-", described_class.config.task_queue_prefix
    end

    it "allows every attribute to be updated via the block" do
      custom_logger = Object.new

      described_class.configure do |config|
        config.target = "localhost:9000"
        config.namespace = "production"
        config.task_queue_prefix = "app-"
        config.default_activity_timeout = 10.minutes
        config.default_retry_initial_interval = 5.seconds
        config.default_retry_backoff = 3.0
        config.default_retry_max_attempts = 4
        config.logger = custom_logger
        config.observability = ActiveJob::Temporal::Observability::Configuration.new
        config.validation_level = :warn
      end

      configured = described_class.config
      assert_equal "localhost:9000", configured.target
      assert_equal "production", configured.namespace
      assert_equal "app-", configured.task_queue_prefix
      assert_equal 10.minutes, configured.default_activity_timeout
      assert_equal 5.seconds, configured.default_retry_initial_interval
      assert_equal 3.0, configured.default_retry_backoff
      assert_equal 4, configured.default_retry_max_attempts
      assert_same custom_logger, configured.logger
      assert_instance_of ActiveJob::Temporal::Observability::Configuration, configured.observability
      assert_same :warn, configured.validation_level
    end

    it "returns the configuration even when no block provided" do
      assert_instance_of ActiveJob::Temporal::Configuration, described_class.configure
    end

    it "clears block state when post-configuration validation fails" do
      assert_raises(ActiveJob::Temporal::ConfigurationError) do
        described_class.configure do |config|
          config.target = "invalid"
        end
      end

      assert_equal false, described_class.config.in_configure_block
    end

    it "keeps the previous configuration when the configure block raises" do
      described_class.configure do |config|
        config.target = "localhost:7233"
        config.namespace = "stable"
      end
      previous_config = described_class.config

      error = assert_raises(RuntimeError) do
        described_class.configure do |config|
          config.target = "localhost:9000"
          config.namespace = "mutated"
          raise "configure failed"
        end
      end

      assert_equal "configure failed", error.message
      assert_same previous_config, described_class.config
      assert_equal "localhost:7233", described_class.config.target
      assert_equal "stable", described_class.config.namespace
      assert_equal false, described_class.config.in_configure_block
    end

    it "keeps the previous configuration when validation fails" do
      described_class.configure do |config|
        config.target = "localhost:7233"
        config.namespace = "stable"
      end
      previous_config = described_class.config

      assert_raises(ActiveJob::Temporal::ConfigurationError) do
        described_class.configure do |config|
          config.target = "invalid"
          config.namespace = "mutated"
        end
      end

      assert_same previous_config, described_class.config
      assert_equal "localhost:7233", described_class.config.target
      assert_equal "stable", described_class.config.namespace
      assert_equal false, described_class.config.in_configure_block
    end

    it "does not leak nested hash mutations when validation fails" do
      described_class.configure do |config|
        config.target = "localhost:7233"
        config.priority_task_queues = { 10 => "critical" }
      end

      assert_raises(ActiveJob::Temporal::ConfigurationError) do
        described_class.configure do |config|
          config.priority_task_queues[20] = "bulk"
          config.target = "invalid"
        end
      end

      assert_equal({ 10 => "critical" }, described_class.config.priority_task_queues)
    end

    it "does not leak in-place string mutations when the configure block raises" do
      described_class.configure do |config|
        config.target = "localhost:7233"
      end

      error = assert_raises(RuntimeError) do
        described_class.configure do |config|
          config.target << "-mutated"
          raise "configure failed"
        end
      end

      assert_equal "configure failed", error.message
      assert_equal "localhost:7233", described_class.config.target
    end

    it "does not leak middleware registrations when validation fails" do
      middleware_class = Class.new do
        def call(_job)
          yield
        end
      end

      assert_raises(ActiveJob::Temporal::ConfigurationError) do
        described_class.configure do |config|
          config.add_middleware middleware_class
          config.target = "invalid"
        end
      end

      assert_empty described_class.config.middleware_chain.to_a
    end

    it "updates the existing configuration after successful validation" do
      previous_config = described_class.config

      described_class.configure do |config|
        config.target = "localhost:9000"
        config.namespace = "production"
      end

      assert_same previous_config, described_class.config
      assert_equal "localhost:9000", described_class.config.target
      assert_equal "production", described_class.config.namespace
    end

    it "logs validation warnings instead of raising when validation_level is warn" do
      warning_logger = Object.new
      warning_calls = call_recorded_method(warning_logger, :warn)

      assert_nothing_raised do
        described_class.configure do |config|
          config.validation_level = :warn
          config.logger = warning_logger
          config.target = "invalid"
        end
      end

      assert_match(/[Tt]arget.*format/, warning_calls.calls_for(:warn).first.arguments.first)
    end

    it "does not duplicate middleware when configure is rerun" do
      middleware_class = Class.new do
        def call(_job)
          yield
        end
      end

      2.times do
        described_class.configure do |config|
          config.add_middleware middleware_class
        end
      end

      assert_equal 1, described_class.config.middleware_chain.to_a.length
    end
  end

  describe ".validate!" do
    it "validates the module configuration" do
      described_class.configure do |config|
        config.target = "localhost:7233"
        config.namespace = "test"
      end

      assert_nothing_raised { described_class.validate! }
    end

    it "raises ConfigurationError for invalid module configuration" do
      described_class.configure do |config|
        config.target = "localhost:7233"
        config.namespace = "test"
      end

      described_class.config.in_configure_block = true
      described_class.config.target = "invalid"
      described_class.config.in_configure_block = false

      error = assert_raises(ActiveJob::Temporal::ConfigurationError) { described_class.validate! }

      assert_match(/[Tt]arget must.*host:port/, error.message)
    end

    it "logs warnings for invalid module configuration when validation_level is warn" do
      warning_logger = Object.new
      warning_calls = call_recorded_method(warning_logger, :warn)

      described_class.config.in_configure_block = true
      described_class.config.validation_level = :warn
      described_class.config.logger = warning_logger
      described_class.config.target = "invalid"
      described_class.config.in_configure_block = false

      assert_nothing_raised { described_class.validate! }
      assert_match(/[Tt]arget.*format/, warning_calls.calls_for(:warn).first.arguments.first)
    end

    it "skips validation when validation_level is none" do
      described_class.config.in_configure_block = true
      described_class.config.validation_level = :none
      described_class.config.target = nil
      described_class.config.in_configure_block = false

      assert_nothing_raised { described_class.validate! }
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

      assert_equal true, system(*command)
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

      assert_equal true, system(*command)
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
            assert_equal "localhost:7233", config.target
            assert_equal "test", config.namespace
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
      assert_match(/localhost:7\d{3}/, final_config.target)
      assert_match(/test-\d/, final_config.namespace)

      case final_config.target
      when "localhost:7233"
        assert_equal "test-0", final_config.namespace
      when "localhost:7234"
        assert_equal "test-1", final_config.namespace
      when "localhost:7235"
        assert_equal "test-2", final_config.namespace
      when "localhost:7236"
        assert_equal "test-3", final_config.namespace
      when "localhost:7237"
        assert_equal "test-4", final_config.namespace
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

      assert(
        (access_log.index("thread1_end") < access_log.index("thread2_start")) ||
          (access_log.index("thread2_end") < access_log.index("thread1_start"))
      )
    end

    it "validates before another configure block can mutate configuration" do
      access_log = []
      access_mutex = Mutex.new
      validation_started = Queue.new
      release_validation = Queue.new

      original_validate = ActiveJob::Temporal::Configuration.instance_method(:validate!)
      ActiveJob::Temporal::Configuration.define_method(:validate!) do
        access_mutex.synchronize { access_log << :validate_start }
        validation_started << true
        release_validation.pop
        access_mutex.synchronize { access_log << :validate_end }
      end

      first_thread = Thread.new do
        described_class.configure do
          access_mutex.synchronize { access_log << :first_configure }
        end
      end

      validation_started.pop

      second_thread = Thread.new do
        described_class.configure do
          access_mutex.synchronize { access_log << :second_configure }
        end
      end

      sleep 0.05
      second_entered_before_first_validation_finished =
        access_mutex.synchronize { access_log.include?(:second_configure) }

      release_validation << true
      validation_started.pop
      release_validation << true

      [first_thread, second_thread].each(&:join)

      assert_equal false, second_entered_before_first_validation_finished
    ensure
      ActiveJob::Temporal::Configuration.define_method(:validate!, original_validate) if original_validate
    end
  end
end
