# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe ActiveJob::Temporal::Schedulable do
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name
        "SchedulableJob"
      end

      def perform(*) = nil
    end
  end

  it "is included into ActiveJob::Base" do
    expect(ActiveJob::Base.included_modules).to include(described_class)
  end

  it "stores a schedule declaration on the job class" do
    schedule = job_class.schedule(cron: "0 2 * * *", timezone: "America/New_York")

    expect(schedule).to be_a(ActiveJob::Temporal::Schedule)
    expect(job_class.temporal_schedule).to be(schedule)
  end

  it "registers a declared schedule explicitly" do
    schedule = instance_double(ActiveJob::Temporal::Schedule)
    allow(ActiveJob::Temporal::Schedule).to receive(:new).and_return(schedule)
    allow(schedule).to receive(:create).and_return("schedule-handle")

    job_class.schedule(cron: "0 2 * * *")

    expect(job_class.create_temporal_schedule).to eq("schedule-handle")
    expect(schedule).to have_received(:create)
  end

  it "registers an ad hoc schedule without storing it first" do
    schedule = instance_double(ActiveJob::Temporal::Schedule)
    allow(ActiveJob::Temporal::Schedule).to receive(:new).and_return(schedule)
    allow(schedule).to receive(:create).and_return("schedule-handle")

    result = job_class.create_temporal_schedule(cron: "0 */6 * * *", timezone: "UTC", overlap_policy: :skip)

    expect(result).to eq("schedule-handle")
    expect(ActiveJob::Temporal::Schedule).to have_received(:new).with(
      job_class,
      cron: "0 */6 * * *",
      timezone: "UTC",
      overlap_policy: :skip
    )
  end

  it "merges declared schedule options when registering with overrides" do
    schedule = instance_double(ActiveJob::Temporal::Schedule)
    allow(ActiveJob::Temporal::Schedule).to receive(:new).and_return(schedule)
    allow(schedule).to receive(:options).and_return(
      cron: "0 2 * * *",
      timezone: "America/New_York",
      overlap_policy: :skip
    )
    allow(schedule).to receive(:create).and_return("schedule-handle")

    job_class.schedule(cron: "0 2 * * *", timezone: "America/New_York", overlap_policy: :skip)

    job_class.create_temporal_schedule(id: "daily-report:42", args: [42])

    expect(ActiveJob::Temporal::Schedule).to have_received(:new).with(
      job_class,
      cron: "0 2 * * *",
      timezone: "America/New_York",
      overlap_policy: :skip,
      id: "daily-report:42",
      args: [42]
    )
  end

  it "raises when registering without a declaration or options" do
    expect { job_class.create_temporal_schedule }
      .to raise_error(ArgumentError, /No schedule defined/)
  end
end
