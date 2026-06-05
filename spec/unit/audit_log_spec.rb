# frozen_string_literal: true

require "spec_helper"

describe ActiveJob::Temporal::AuditLog do
  let(:log_io) { StringIO.new }
  let(:ruby_logger) do
    Logger.new(log_io).tap do |logger|
      logger.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
    end
  end
  let(:fixed_time) { Time.utc(2026, 5, 21, 12, 0, 0) }

  before do
    @previous_audit_log = ActiveJob::Temporal.config.audit_log
    @previous_audit_logger = ActiveJob::Temporal.config.audit_logger
    @previous_logger = ActiveJob::Temporal.config.logger
    @previous_identity = ActiveJob::Temporal.config.identity
    ActiveJob::Temporal.config.audit_log = false
    ActiveJob::Temporal.config.audit_logger = nil
    ActiveJob::Temporal.config.logger = ruby_logger
    ActiveJob::Temporal.config.identity = nil
    call_recorded_method(Time, :now, returns: fixed_time)
  end

  after do
    ActiveJob::Temporal.config.audit_log = @previous_audit_log
    ActiveJob::Temporal.config.audit_logger = @previous_audit_logger
    ActiveJob::Temporal.config.logger = @previous_logger
    ActiveJob::Temporal.config.identity = @previous_identity
  end

  describe ".record" do
    it "does not log when audit logging is disabled" do
      described_class.record("job.started", job_id: "job-1")

      assert_equal "", log_io.string
    end

    it "writes structured JSON through the configured logger when enabled" do
      ActiveJob::Temporal.config.audit_log = true

      described_class.record("job.started", job_id: "job-1", workflow_id: "workflow-1")

      payload = parsed_lines.first
      assert_equal "job.started", payload["event"]
      assert_equal "2026-05-21T12:00:00Z", payload["timestamp"]
      assert_equal "job-1", payload["job_id"]
      assert_equal "workflow-1", payload["workflow_id"]
    end

    it "uses audit_logger when configured" do
      ActiveJob::Temporal.config.audit_log = true
      audit_io = StringIO.new
      audit_logger = Logger.new(audit_io)
      audit_logger.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
      ActiveJob::Temporal.config.audit_logger = audit_logger

      described_class.record("job.completed", job_id: "job-1")

      assert_equal "", log_io.string
      assert_equal "job.completed", JSON.parse(audit_io.string)["event"]
    end

    it "keeps JSON output for plain audit loggers when SemanticLogger is loaded" do
      stub_const("SemanticLogger", Module.new)
      ActiveJob::Temporal.config.audit_log = true

      described_class.record("job.started", job_id: "job-1")

      assert_equal "job.started", JSON.parse(log_io.string)["event"]
    end

    it "removes raw arguments, payloads, and results from attributes" do
      ActiveJob::Temporal.config.audit_log = true

      described_class.record(
        "job.completed",
        job_id: "job-1",
        arguments: ["secret"],
        payload: { arguments: ["secret"] },
        result: "secret"
      )

      payload = parsed_lines.first
      assert_equal "job-1", payload["job_id"]
      refute payload.key?("arguments")
      refute payload.key?("payload")
      refute payload.key?("result")
    end

    it "removes free-form upstream error fields from attributes" do
      ActiveJob::Temporal.config.audit_log = true

      described_class.record(
        "job.failed",
        job_id: "job-1",
        message: "connection failed for postgres://user:secret@db.internal",
        target: "temporal://token:secret@temporal.internal:7233",
        error: "OpenSSL::SSL::SSLError: private-key secret",
        error_message: "x-temporal-api-key=secret",
        exception: RuntimeError.new("bearer secret"),
        cause: RuntimeError.new("nested secret")
      )

      payload = parsed_lines.first
      assert_equal "job-1", payload["job_id"]
      refute payload.key?("message")
      refute payload.key?("target")
      refute payload.key?("error")
      refute payload.key?("error_message")
      refute payload.key?("exception")
      refute payload.key?("cause")
      refute_includes log_io.string, "secret"
    end
  end

  describe ".error_attributes" do
    it "includes a stable fingerprint without the raw error message" do
      error = RuntimeError.new("postgres://user:secret@db.internal")

      attributes = described_class.error_attributes(error)

      assert_equal "RuntimeError", attributes[:error_class]
      assert_match(/\A[0-9a-f]{64}\z/, attributes[:error_fingerprint])
      refute_includes attributes.values, error.message
    end
  end

  describe ".activity_attributes_from_payload" do
    it "adds payload metadata and Temporal correlation IDs without arguments" do
      info = Struct.new(:workflow_id, :workflow_run_id, :attempt).new("workflow-1", "run-1", 2)
      context = Struct.new(:info).new(info)

      call_recorded_method(Temporalio::Activity::Context, :exist?, returns: true)
      call_recorded_method(Temporalio::Activity::Context, :current, returns: context)
      ActiveJob::Temporal.config.identity = "worker-1"

      attributes = described_class.activity_attributes_from_payload(
        "job_class" => "AuditJob",
        "job_id" => "job-1",
        "queue_name" => "critical",
        "arguments" => ["secret"]
      )

      assert_equal "AuditJob", attributes[:job_class]
      assert_equal "job-1", attributes[:job_id]
      assert_equal "critical", attributes[:queue]
      assert_equal "workflow-1", attributes[:workflow_id]
      assert_equal "run-1", attributes[:run_id]
      assert_equal 2, attributes[:attempt]
      assert_equal "worker-1", attributes[:worker_id]
      refute attributes.key?(:arguments)
    end
  end

  def parsed_lines
    log_io.string.lines.map { |line| JSON.parse(line) }
  end
end
