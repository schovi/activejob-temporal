# frozen_string_literal: true

require "spec_helper"
require "active_job"

module ScheduleSpecSupport
  class FakeClient
    attr_accessor :create_schedule_result, :create_schedule_error, :schedule_handle_result
    attr_reader :create_schedule_calls, :schedule_handle_calls

    def initialize
      @create_schedule_result = "schedule-handle"
      @create_schedule_calls = []
      @schedule_handle_calls = []
    end

    def create_schedule(id, schedule, trigger_immediately:, memo:, search_attributes:)
      @create_schedule_calls << {
        id: id,
        schedule: schedule,
        trigger_immediately: trigger_immediately,
        memo: memo,
        search_attributes: search_attributes
      }
      raise create_schedule_error if create_schedule_error

      create_schedule_result
    end

    def schedule_handle(id)
      @schedule_handle_calls << id
      schedule_handle_result
    end
  end

  class FakePayloadBuilder
    attr_reader :build_calls

    def initialize(payload)
      @payload = payload
      @build_calls = []
    end

    def build(job, encryption_context:)
      @build_calls << { job: job, encryption_context: encryption_context }
      @payload
    end
  end
end

describe ActiveJob::Temporal::Schedule do
  let(:client) { ScheduleSpecSupport::FakeClient.new }
  let(:config) { build_configuration }
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      queue_as :reports

      def self.name
        "ScheduledReportJob"
      end

      def perform(*) = nil
    end
  end

  before do
    @logger_events = call_recorded_method(ActiveJob::Temporal::Logger, :log_event)
    @audit_events = call_recorded_method(ActiveJob::Temporal::AuditLog, :record)
  end

  it "builds a Temporal schedule that starts the ActiveJob workflow" do
    schedule = described_class.new(
      job_class,
      cron: "0 2 * * *",
      timezone: "America/New_York",
      args: ["daily"],
      client: client,
      config: config
    )

    temporal_schedule = schedule.to_temporal_schedule

    assert_equal ["0 2 * * *"], temporal_schedule.spec.cron_expressions
    assert_equal "America/New_York", temporal_schedule.spec.time_zone_name
    assert_equal "AjWorkflow", temporal_schedule.action.workflow
    assert_equal "reports", temporal_schedule.action.task_queue
    assert_equal "ScheduledReportJob", temporal_schedule.action.args.first[:job_class]
    refute temporal_schedule.action.args.first.key?(:arguments)
    assert_equal ["daily"], temporal_schedule.action.args.first[:active_job]["arguments"]
    assert_hash_includes(
      {
        schedule_id: "ajsch:ScheduledReportJob",
        schedule_workflow_id_prefix: "ajschwf:ajsch:ScheduledReportJob",
        payload_encryption_context: { namespace: "default", workflow_id: "ajschwf:ajsch:ScheduledReportJob" }
      },
      temporal_schedule.action.args.first
    )
  end

  it "creates the schedule through the Temporal client" do
    schedule = described_class.new(
      job_class,
      cron: "0 */6 * * *",
      timezone: "UTC",
      overlap_policy: :skip,
      client: client,
      config: config
    )

    result = schedule.create

    assert_equal "schedule-handle", result

    create_call = client.create_schedule_calls.first
    assert_equal "ajsch:ScheduledReportJob", create_call[:id]
    assert_instance_of Temporalio::Client::Schedule, create_call[:schedule]
    assert_equal false, create_call[:trigger_immediately]
    assert_nil create_call[:memo]
    assert_nil create_call[:search_attributes]
  end

  it "returns the existing schedule handle when the schedule already exists" do
    existing_handle = Object.new
    config.task_queue_prefix = "prod-"
    client.create_schedule_error = Temporalio::Error::ScheduleAlreadyRunningError.new
    client.schedule_handle_result = existing_handle

    schedule = described_class.new(
      job_class,
      cron: "0 */6 * * *",
      queue: "billing",
      client: client,
      config: config
    )

    assert_same existing_handle, schedule.create
    assert_equal ["ajsch:ScheduledReportJob"], client.schedule_handle_calls
    assert_called_with(
      @logger_events,
      :log_event,
      "schedule_created",
      {
        schedule_id: "ajsch:ScheduledReportJob",
        job_class: "ScheduledReportJob",
        cron: "0 */6 * * *",
        timezone: "UTC",
        overlap_policy: :skip,
        task_queue: "prod-billing",
        duplicate: true
      }
    )
  end

  it "maps supported overlap policies" do
    schedule = described_class.new(
      job_class,
      cron: "0 * * * *",
      overlap_policy: :allow_all,
      client: client,
      config: config
    )

    assert_equal Temporalio::Client::Schedule::OverlapPolicy::ALLOW_ALL,
                 schedule.to_temporal_schedule.policy.overlap
  end

  it "treats buffer as buffer_one" do
    schedule = described_class.new(
      job_class,
      cron: "0 * * * *",
      overlap_policy: :buffer,
      client: client,
      config: config
    )

    assert_equal Temporalio::Client::Schedule::OverlapPolicy::BUFFER_ONE,
                 schedule.to_temporal_schedule.policy.overlap
  end

  it "uses explicit IDs and queues" do
    schedule = described_class.new(
      job_class,
      id: "billing-reports",
      cron: "0 3 * * *",
      queue: "billing",
      client: client,
      config: config
    )

    temporal_schedule = schedule.to_temporal_schedule

    assert_equal "billing-reports", schedule.id
    assert_equal "ajschwf:billing-reports", temporal_schedule.action.id
    assert_equal "billing", temporal_schedule.action.task_queue
  end

  it "keeps the schedule ID in search attributes for occurrence grouping" do
    schedule = described_class.new(
      job_class,
      cron: "0 3 * * *",
      client: client,
      config: config
    )

    call_recorded_method(ActiveJob::Temporal::SearchAttributes, :for) do |job|
      assert_equal "ajsch:ScheduledReportJob", job.job_id
      "search-attributes"
    end

    assert_equal "search-attributes", schedule.to_temporal_schedule.action.search_attributes
  end

  it "lets Temporal append occurrence entropy to scheduled workflow IDs" do
    schedule = described_class.new(
      job_class,
      id: "billing-reports",
      cron: "0 3 * * *",
      client: client,
      config: config
    )

    temporal_schedule = schedule.to_temporal_schedule

    assert_equal "ajschwf:billing-reports", temporal_schedule.action.id
    assert_equal false, temporal_schedule.policy._to_proto.keep_original_workflow_id
  end

  it "builds encrypted payloads with the scheduled workflow context" do
    payload = { job_class: "ScheduledReportJob", job_id: "ajsch:ScheduledReportJob", queue_name: "reports" }
    payload_builder = ScheduleSpecSupport::FakePayloadBuilder.new(payload)
    schedule = described_class.new(
      job_class,
      cron: "0 3 * * *",
      client: client,
      config: config,
      payload_builder: payload_builder
    )

    temporal_schedule = schedule.to_temporal_schedule

    assert_equal(
      payload.merge(
        schedule_id: "ajsch:ScheduledReportJob",
        schedule_workflow_id_prefix: "ajschwf:ajsch:ScheduledReportJob",
        payload_encryption_context: { namespace: "default", workflow_id: "ajschwf:ajsch:ScheduledReportJob" }
      ),
      temporal_schedule.action.args.first
    )
    build_call = payload_builder.build_calls.first
    assert_instance_of job_class, build_call[:job]
    assert_equal(
      { namespace: "default", workflow_id: "ajschwf:ajsch:ScheduledReportJob" },
      build_call[:encryption_context]
    )
  end

  it "uses injected configuration when resolving task queues" do
    config.task_queue_prefix = "prod-"
    schedule = described_class.new(
      job_class,
      cron: "0 3 * * *",
      queue: "billing",
      client: client,
      config: config
    )

    temporal_schedule = schedule.to_temporal_schedule

    assert_equal "prod-billing", temporal_schedule.action.task_queue
  end

  it "logs schedule creation" do
    schedule = described_class.new(
      job_class,
      cron: "0 2 * * *",
      client: client,
      config: config
    )

    schedule.create

    assert_called_with(
      @logger_events,
      :log_event,
      "schedule_created",
      {
        schedule_id: "ajsch:ScheduledReportJob",
        job_class: "ScheduledReportJob",
        cron: "0 2 * * *",
        timezone: "UTC",
        overlap_policy: :skip,
        task_queue: "reports",
        duplicate: false
      }
    )
  end

  it "records a schedule audit event" do
    schedule = described_class.new(
      job_class,
      cron: "0 2 * * *",
      client: client,
      config: config
    )

    schedule.create

    assert_called_with(
      @audit_events,
      :record,
      "schedule.created",
      {
        schedule_id: "ajsch:ScheduledReportJob",
        job_class: "ScheduledReportJob",
        cron: "0 2 * * *",
        timezone: "UTC",
        overlap_policy: :skip,
        task_queue: "reports",
        duplicate: false
      }
    )
  end

  it "rejects blank cron expressions" do
    error = assert_raises(ArgumentError) do
      described_class.new(job_class, cron: "", client: client, config: config)
    end

    assert_match(/cron must be present/, error.message)
  end

  it "rejects unsupported overlap policies" do
    error = assert_raises(ArgumentError) do
      described_class.new(job_class, cron: "0 * * * *", overlap_policy: :replace, client: client, config: config)
    end

    assert_match(/Unsupported overlap_policy/, error.message)
  end

  private

  def build_configuration
    config = ActiveJob::Temporal::Configuration.new
    config.task_queue_prefix = nil
    config
  end
end
