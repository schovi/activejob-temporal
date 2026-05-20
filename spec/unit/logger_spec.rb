# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::Logger do
  subject(:logger_helper) { described_class }

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
    allow(Time).to receive(:now).and_return(fixed_time)
  end

  after do
    ActiveJob::Temporal.config.logger = @previous_logger
  end

  describe ".log_event" do
    it "writes JSON with standard attributes" do
      logger_helper.log_event("workflow_enqueued", workflow_id: "abc123")

      payload = parsed_lines.first
      expect(payload["event"]).to eq("workflow_enqueued")
      expect(payload["timestamp"]).to eq("2025-10-25T12:00:00Z")
      expect(payload["workflow_id"]).to eq("abc123")
    end

    it "includes custom attributes" do
      logger_helper.log_event("activity_completed", duration_ms: 1234, job_class: "ExampleJob")

      payload = parsed_lines.first
      expect(payload["duration_ms"]).to eq(1234)
      expect(payload["job_class"]).to eq("ExampleJob")
    end

    it "handles nil attributes by sending an empty payload" do
      logger_helper.log_event("workflow_enqueued", nil)

      payload = parsed_lines.first
      expect(payload["event"]).to eq("workflow_enqueued")
      expect(payload).to eq(
        "event" => "workflow_enqueued",
        "timestamp" => "2025-10-25T12:00:00Z"
      )
    end
  end

  describe "log levels" do
    it "supports warn level" do
      logger_helper.warn("activity_retry", attempt: 2)

      payload = parsed_lines.first
      expect(payload["event"]).to eq("activity_retry")
      expect(payload["attempt"]).to eq(2)
    end

    it "supports error level" do
      logger_helper.error("activity_failed", exception_class: "StandardError")

      payload = parsed_lines.first
      expect(payload["event"]).to eq("activity_failed")
      expect(payload["exception_class"]).to eq("StandardError")
    end
  end

  describe "validation" do
    it "raises when attributes are not a Hash" do
      expect do
        logger_helper.log_event("invalid_attributes", %w[a b])
      end.to raise_error(ArgumentError, /attributes/)
    end

    it "raises when event_name is not a String or Symbol" do
      expect do
        logger_helper.log_event(123, {})
      end.to raise_error(ArgumentError, /event_name/)
    end
  end

  describe "logger backends" do
    it "can write to a provided logger instead of the global logger" do
      custom_io = StringIO.new
      custom_logger = Logger.new(custom_io)
      custom_logger.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }

      logger_helper.log_to(custom_logger, :info, "audit.event", job_id: "job-1")

      expect(log_io.string).to eq("")
      expect(JSON.parse(custom_io.string)).to include(
        "event" => "audit.event",
        "job_id" => "job-1"
      )
    end

    it "skips logging when the configured logger does not implement the level" do
      null_logger = double("NullLogger")
      ActiveJob::Temporal.config.logger = null_logger
      allow(null_logger).to receive(:respond_to?).with(:info).and_return(false)

      expect { logger_helper.info("noop") }.not_to raise_error
      expect(log_io.string).to eq("")
    end

    it "emits structured payloads when the configured logger is SemanticLogger" do
      semantic_logger = build_semantic_logger

      logger_helper.info(:structured_event, workflow_id: "abc123")

      expect(semantic_logger.payload[:event]).to eq(:structured_event)
      expect(semantic_logger.payload[:workflow_id]).to eq("abc123")
    end

    it "JSON serializes for Ruby Logger when SemanticLogger is loaded" do
      stub_const("SemanticLogger", Module.new)

      logger_helper.info("ruby_logger_event", job_id: "job-1")

      payload = parsed_lines.first
      expect(payload["event"]).to eq("ruby_logger_event")
      expect(payload["job_id"]).to eq("job-1")
    end

    it "falls back to JSON serialization when SemanticLogger is not available" do
      logger_helper.info("fallback_event", workflow_id: "xyz789")

      payload = parsed_lines.first
      expect(payload["event"]).to eq("fallback_event")
      expect(payload["workflow_id"]).to eq("xyz789")
      expect(payload["timestamp"]).to eq("2025-10-25T12:00:00Z")
    end

    it "JSON serializes payload without SemanticLogger" do
      logger_helper.info("json_test", key: "value")

      logged_output = log_io.string.strip
      parsed = JSON.parse(logged_output)
      expect(parsed["event"]).to eq("json_test")
      expect(parsed["key"]).to eq("value")
    end
  end

  describe "SemanticLogger detection" do
    it "properly detects SemanticLogger instances" do
      semantic_logger = build_semantic_logger

      logger_helper.info(:hash_event, data: "test")

      expect(semantic_logger.payload).to be_a(Hash)
      expect(semantic_logger.payload[:event]).to eq(:hash_event)
    end

    it "properly detects when SemanticLogger is not defined" do
      logger_helper.info("no_semantic", test: true)

      logged = log_io.string.strip
      parsed = JSON.parse(logged)
      expect(parsed).to be_a(Hash)
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
