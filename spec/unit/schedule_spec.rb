# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe ActiveJob::Temporal::Schedule do
  let(:client) { instance_double(Temporalio::Client) }
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
    allow(client).to receive(:create_schedule).and_return("schedule-handle")
    allow(ActiveJob::Temporal::Logger).to receive(:log_event)
    allow(ActiveJob::Temporal::AuditLog).to receive(:record)
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

    expect(temporal_schedule.spec.cron_expressions).to eq(["0 2 * * *"])
    expect(temporal_schedule.spec.time_zone_name).to eq("America/New_York")
    expect(temporal_schedule.action.workflow).to eq("AjWorkflow")
    expect(temporal_schedule.action.task_queue).to eq("reports")
    expect(temporal_schedule.action.args.first[:job_class]).to eq("ScheduledReportJob")
    expect(temporal_schedule.action.args.first).not_to have_key(:arguments)
    expect(temporal_schedule.action.args.first[:active_job]["arguments"]).to eq(["daily"])
    expect(temporal_schedule.action.args.first).to include(
      schedule_id: "ajsch:ScheduledReportJob",
      schedule_workflow_id_prefix: "ajschwf:ajsch:ScheduledReportJob",
      payload_encryption_context: { namespace: "default", workflow_id: "ajschwf:ajsch:ScheduledReportJob" }
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

    expect(result).to eq("schedule-handle")
    expect(client).to have_received(:create_schedule).with(
      "ajsch:ScheduledReportJob",
      instance_of(Temporalio::Client::Schedule),
      trigger_immediately: false,
      memo: nil,
      search_attributes: nil
    )
  end

  it "returns the existing schedule handle when the schedule already exists" do
    existing_handle = instance_double(Temporalio::Client::ScheduleHandle)
    config.task_queue_prefix = "prod-"
    allow(client).to receive(:create_schedule).and_raise(Temporalio::Error::ScheduleAlreadyRunningError.new)
    allow(client).to receive(:schedule_handle).with("ajsch:ScheduledReportJob").and_return(existing_handle)

    schedule = described_class.new(
      job_class,
      cron: "0 */6 * * *",
      queue: "billing",
      client: client,
      config: config
    )

    expect(schedule.create).to be(existing_handle)
    expect(ActiveJob::Temporal::Logger).to have_received(:log_event).with(
      "schedule_created",
      schedule_id: "ajsch:ScheduledReportJob",
      job_class: "ScheduledReportJob",
      cron: "0 */6 * * *",
      timezone: "UTC",
      overlap_policy: :skip,
      task_queue: "prod-billing",
      duplicate: true
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

    expect(schedule.to_temporal_schedule.policy.overlap)
      .to eq(Temporalio::Client::Schedule::OverlapPolicy::ALLOW_ALL)
  end

  it "treats buffer as buffer_one" do
    schedule = described_class.new(
      job_class,
      cron: "0 * * * *",
      overlap_policy: :buffer,
      client: client,
      config: config
    )

    expect(schedule.to_temporal_schedule.policy.overlap)
      .to eq(Temporalio::Client::Schedule::OverlapPolicy::BUFFER_ONE)
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

    expect(schedule.id).to eq("billing-reports")
    expect(temporal_schedule.action.id).to eq("ajschwf:billing-reports")
    expect(temporal_schedule.action.task_queue).to eq("billing")
  end

  it "keeps the schedule ID in search attributes for occurrence grouping" do
    schedule = described_class.new(
      job_class,
      cron: "0 3 * * *",
      client: client,
      config: config
    )

    expect(ActiveJob::Temporal::SearchAttributes).to receive(:for) do |job|
      expect(job.job_id).to eq("ajsch:ScheduledReportJob")
      "search-attributes"
    end

    expect(schedule.to_temporal_schedule.action.search_attributes).to eq("search-attributes")
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

    expect(temporal_schedule.action.id).to eq("ajschwf:billing-reports")
    expect(temporal_schedule.policy._to_proto.keep_original_workflow_id).to eq(false)
  end

  it "builds encrypted payloads with the scheduled workflow context" do
    payload_builder = instance_double(ActiveJob::Temporal::JobPayloadBuilder)
    payload = { job_class: "ScheduledReportJob", job_id: "ajsch:ScheduledReportJob", queue_name: "reports" }
    schedule = described_class.new(
      job_class,
      cron: "0 3 * * *",
      client: client,
      config: config,
      payload_builder: payload_builder
    )

    allow(payload_builder).to receive(:build)
      .with(
        an_instance_of(job_class),
        encryption_context: { namespace: "default", workflow_id: "ajschwf:ajsch:ScheduledReportJob" }
      )
      .and_return(payload)

    temporal_schedule = schedule.to_temporal_schedule

    expect(temporal_schedule.action.args.first).to eq(
      payload.merge(
        schedule_id: "ajsch:ScheduledReportJob",
        schedule_workflow_id_prefix: "ajschwf:ajsch:ScheduledReportJob",
        payload_encryption_context: { namespace: "default", workflow_id: "ajschwf:ajsch:ScheduledReportJob" }
      )
    )
    expect(payload_builder).to have_received(:build).with(
      an_instance_of(job_class),
      encryption_context: { namespace: "default", workflow_id: "ajschwf:ajsch:ScheduledReportJob" }
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

    expect(temporal_schedule.action.task_queue).to eq("prod-billing")
  end

  it "logs schedule creation" do
    schedule = described_class.new(
      job_class,
      cron: "0 2 * * *",
      client: client,
      config: config
    )

    schedule.create

    expect(ActiveJob::Temporal::Logger).to have_received(:log_event).with(
      "schedule_created",
      schedule_id: "ajsch:ScheduledReportJob",
      job_class: "ScheduledReportJob",
      cron: "0 2 * * *",
      timezone: "UTC",
      overlap_policy: :skip,
      task_queue: "reports",
      duplicate: false
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

    expect(ActiveJob::Temporal::AuditLog).to have_received(:record).with(
      "schedule.created",
      schedule_id: "ajsch:ScheduledReportJob",
      job_class: "ScheduledReportJob",
      cron: "0 2 * * *",
      timezone: "UTC",
      overlap_policy: :skip,
      task_queue: "reports",
      duplicate: false
    )
  end

  it "rejects blank cron expressions" do
    expect do
      described_class.new(job_class, cron: "", client: client, config: config)
    end.to raise_error(ArgumentError, /cron must be present/)
  end

  it "rejects unsupported overlap policies" do
    expect do
      described_class.new(job_class, cron: "0 * * * *", overlap_policy: :replace, client: client, config: config)
    end.to raise_error(ArgumentError, /Unsupported overlap_policy/)
  end

  private

  def build_configuration
    config = ActiveJob::Temporal::Configuration.new
    config.task_queue_prefix = nil
    config
  end
end
