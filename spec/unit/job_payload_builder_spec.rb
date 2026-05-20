# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe ActiveJob::Temporal::JobPayloadBuilder do
  let(:config) { ActiveJob::Temporal::Configuration.new }

  it "builds a workflow payload with global activity defaults" do
    config.default_heartbeat_timeout = 45.seconds
    config.default_schedule_to_start_timeout = 2.minutes
    config.default_schedule_to_close_timeout = 20.minutes
    job = build_job("PayloadBuilderJob")

    payload = described_class.new(config).build(job)

    expect(payload[:default_activity_options]).to eq(
      start_to_close_timeout: 900.0,
      schedule_to_close_timeout: 1200.0,
      schedule_to_start_timeout: 120.0,
      heartbeat_timeout: 45.0
    )
  end

  it "includes per-job temporal options" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "ScheduledTimeoutJob"

      temporal_options start_to_close_timeout: 2.hours
    end
    job = job_class.new

    payload = described_class.new(config).build(job)

    expect(payload[:temporal_options]).to eq(start_to_close_timeout: 7200.0)
  end

  private

  def build_job(name)
    Class.new(ActiveJob::Base) do
      define_singleton_method(:name) { name }
    end.new
  end
end
