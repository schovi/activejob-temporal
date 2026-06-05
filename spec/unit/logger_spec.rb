# frozen_string_literal: true

require "spec_helper"

describe ActiveJob::Temporal::Logger do
  let(:logger_helper) { described_class }

  let(:log_io) { StringIO.new }
  let(:ruby_logger) do
    Logger.new(log_io).tap do |logger|
      logger.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
    end
  end
  let(:fixed_time) { Time.utc(2025, 10, 25, 12, 0, 0) }

  before do
    @previous_logger = ActiveJob::Temporal.config.logger
    ActiveJob::Temporal.config.logger = ruby_logger
    call_recorded_method(Time, :now, returns: fixed_time)
  end

  after do
    ActiveJob::Temporal.config.logger = @previous_logger
  end

  describe ".log_event" do
    it "writes JSON with standard attributes" do
      logger_helper.log_event("workflow_enqueued", workflow_id: "abc123")

      payload = parsed_lines.first
      assert_equal "workflow_enqueued", payload["event"]
      assert_equal "2025-10-25T12:00:00Z", payload["timestamp"]
      assert_equal "abc123", payload["workflow_id"]
    end

    it "includes custom attributes" do
      logger_helper.log_event("activity_completed", duration_ms: 1234, job_class: "ExampleJob")

      payload = parsed_lines.first
      assert_equal 1234, payload["duration_ms"]
      assert_equal "ExampleJob", payload["job_class"]
    end

    it "handles nil attributes by sending an empty payload" do
      logger_helper.log_event("workflow_enqueued", nil)

      payload = parsed_lines.first
      assert_equal "workflow_enqueued", payload["event"]
      assert_equal(
        {
          "event" => "workflow_enqueued",
          "timestamp" => "2025-10-25T12:00:00Z"
        },
        payload
      )
    end
  end

  describe "log levels" do
    it "supports warn level" do
      logger_helper.warn("activity_retry", attempt: 2)

      payload = parsed_lines.first
      assert_equal "activity_retry", payload["event"]
      assert_equal 2, payload["attempt"]
    end

    it "supports error level" do
      logger_helper.error("activity_failed", exception_class: "StandardError")

      payload = parsed_lines.first
      assert_equal "activity_failed", payload["event"]
      assert_equal "StandardError", payload["exception_class"]
    end
  end

  describe "validation" do
    it "raises when attributes are not a Hash" do
      error = assert_raises(ArgumentError) do
        logger_helper.log_event("invalid_attributes", %w[a b])
      end
      assert_match(/attributes/, error.message)
    end

    it "raises when event_name is not a String or Symbol" do
      error = assert_raises(ArgumentError) do
        logger_helper.log_event(123, {})
      end
      assert_match(/event_name/, error.message)
    end
  end

  describe "logger backends" do
    it "can write to a provided logger instead of the global logger" do
      custom_io = StringIO.new
      custom_logger = Logger.new(custom_io)
      custom_logger.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }

      logger_helper.log_to(custom_logger, :info, "audit.event", job_id: "job-1")

      assert_equal "", log_io.string
      payload = JSON.parse(custom_io.string)
      assert_equal "audit.event", payload["event"]
      assert_equal "job-1", payload["job_id"]
    end

    it "skips logging when the configured logger does not implement the level" do
      null_logger = Object.new
      ActiveJob::Temporal.config.logger = null_logger

      logger_helper.info("noop")

      assert_equal "", log_io.string
    end

    it "emits structured payloads when the configured logger is SemanticLogger" do
      semantic_logger = build_semantic_logger

      logger_helper.info(:structured_event, workflow_id: "abc123")

      assert_equal :structured_event, semantic_logger.payload[:event]
      assert_equal "abc123", semantic_logger.payload[:workflow_id]
    end

    it "JSON serializes for Ruby Logger when SemanticLogger is loaded" do
      stub_const("SemanticLogger", Module.new)

      logger_helper.info("ruby_logger_event", job_id: "job-1")

      payload = parsed_lines.first
      assert_equal "ruby_logger_event", payload["event"]
      assert_equal "job-1", payload["job_id"]
    end

    it "falls back to JSON serialization when SemanticLogger is not available" do
      logger_helper.info("fallback_event", workflow_id: "xyz789")

      payload = parsed_lines.first
      assert_equal "fallback_event", payload["event"]
      assert_equal "xyz789", payload["workflow_id"]
      assert_equal "2025-10-25T12:00:00Z", payload["timestamp"]
    end

    it "JSON serializes payload without SemanticLogger" do
      logger_helper.info("json_test", key: "value")

      logged_output = log_io.string.strip
      parsed = JSON.parse(logged_output)
      assert_equal "json_test", parsed["event"]
      assert_equal "value", parsed["key"]
    end

    it "escapes control characters before writing JSON payloads" do
      logger_helper.info(
        "event\rname",
        job_id: "job-1\nforged",
        nested: { "reason\n" => "bad\tvalue" },
        tags: ["one", "two\r"]
      )

      payload = parsed_lines.first
      assert_equal "event\\u000Dname", payload["event"]
      assert_equal "job-1\\u000Aforged", payload["job_id"]
      assert_equal({ "reason\\u000A" => "bad\\u0009value" }, payload["nested"])
      assert_equal ["one", "two\\u000D"], payload["tags"]
    end
  end

  describe "SemanticLogger detection" do
    it "properly detects SemanticLogger instances" do
      semantic_logger = build_semantic_logger

      logger_helper.info(:hash_event, data: "test")

      assert_kind_of Hash, semantic_logger.payload
      assert_equal :hash_event, semantic_logger.payload[:event]
    end

    it "properly detects when SemanticLogger is not defined" do
      logger_helper.info("no_semantic", test: true)

      logged = log_io.string.strip
      parsed = JSON.parse(logged)
      assert_kind_of Hash, parsed
    end

    it "escapes control characters before sending structured SemanticLogger payloads" do
      semantic_logger = build_semantic_logger

      logger_helper.info("semantic_event", workflow_id: "wf-1\nforged")

      assert_equal "wf-1\\u000Aforged", semantic_logger.payload[:workflow_id]
    end
  end

  def parsed_lines
    log_io.string.lines.map { |line| JSON.parse(line) }
  end

  def build_semantic_logger
    stub_const("SemanticLogger", Module.new)
    semantic_logger_class = Class.new do
      attr_reader :payload

      def info(payload)
        @payload = payload
      end
    end
    stub_const("SemanticLogger::Logger", semantic_logger_class)
    semantic_logger_class.new.tap do |logger|
      ActiveJob::Temporal.config.logger = logger
    end
  end
end
