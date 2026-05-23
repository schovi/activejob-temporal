# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::AuditLog do
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
    allow(Time).to receive(:now).and_return(fixed_time)
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

      expect(log_io.string).to eq("")
    end

    it "writes structured JSON through the configured logger when enabled" do
      ActiveJob::Temporal.config.audit_log = true

      described_class.record("job.started", job_id: "job-1", workflow_id: "workflow-1")

      payload = parsed_lines.first
      expect(payload["event"]).to eq("job.started")
      expect(payload["timestamp"]).to eq("2026-05-21T12:00:00Z")
      expect(payload["job_id"]).to eq("job-1")
      expect(payload["workflow_id"]).to eq("workflow-1")
    end

    it "uses audit_logger when configured" do
      ActiveJob::Temporal.config.audit_log = true
      audit_io = StringIO.new
      audit_logger = Logger.new(audit_io)
      audit_logger.formatter = proc { |_severity, _datetime, _progname, msg| "#{msg}\n" }
      ActiveJob::Temporal.config.audit_logger = audit_logger

      described_class.record("job.completed", job_id: "job-1")

      expect(log_io.string).to eq("")
      expect(JSON.parse(audit_io.string)["event"]).to eq("job.completed")
    end

    it "keeps JSON output for plain audit loggers when SemanticLogger is loaded" do
      stub_const("SemanticLogger", Module.new)
      ActiveJob::Temporal.config.audit_log = true

      described_class.record("job.started", job_id: "job-1")

      expect(JSON.parse(log_io.string)["event"]).to eq("job.started")
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
      expect(payload).to include("job_id" => "job-1")
      expect(payload).not_to have_key("arguments")
      expect(payload).not_to have_key("payload")
      expect(payload).not_to have_key("result")
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
      expect(payload).to include("job_id" => "job-1")
      expect(payload).not_to have_key("message")
      expect(payload).not_to have_key("target")
      expect(payload).not_to have_key("error")
      expect(payload).not_to have_key("error_message")
      expect(payload).not_to have_key("exception")
      expect(payload).not_to have_key("cause")
      expect(log_io.string).not_to include("secret")
    end
  end

  describe ".error_attributes" do
    it "includes a stable fingerprint without the raw error message" do
      error = RuntimeError.new("postgres://user:secret@db.internal")

      attributes = described_class.error_attributes(error)

      expect(attributes).to include(error_class: "RuntimeError")
      expect(attributes[:error_fingerprint]).to match(/\A[0-9a-f]{64}\z/)
      expect(attributes.values).not_to include(error.message)
    end
  end

  describe ".activity_attributes_from_payload" do
    it "adds payload metadata and Temporal correlation IDs without arguments" do
      info = instance_double(
        "Temporalio::Activity::Info",
        workflow_id: "workflow-1",
        workflow_run_id: "run-1",
        attempt: 2
      )
      context = instance_double("Temporalio::Activity::Context", info: info)

      allow(Temporalio::Activity::Context).to receive(:exist?).and_return(true)
      allow(Temporalio::Activity::Context).to receive(:current).and_return(context)
      ActiveJob::Temporal.config.identity = "worker-1"

      attributes = described_class.activity_attributes_from_payload(
        "job_class" => "AuditJob",
        "job_id" => "job-1",
        "queue_name" => "critical",
        "arguments" => ["secret"]
      )

      expect(attributes).to include(
        job_class: "AuditJob",
        job_id: "job-1",
        queue: "critical",
        workflow_id: "workflow-1",
        run_id: "run-1",
        attempt: 2,
        worker_id: "worker-1"
      )
      expect(attributes).not_to have_key(:arguments)
    end
  end

  def parsed_lines
    log_io.string.lines.map { |line| JSON.parse(line) }
  end
end
