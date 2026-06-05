# frozen_string_literal: true

require "spec_helper"
require "active_job"

describe ActiveJob::Temporal::Schedulable do
  let(:job_class) do
    Class.new(ActiveJob::Base) do
      def self.name
        "SchedulableJob"
      end

      def perform(*) = nil
    end
  end

  it "is included into ActiveJob::Base" do
    assert_includes ActiveJob::Base.included_modules, described_class
  end

  it "does not add a generic schedule class method" do
    refute_respond_to job_class, :schedule
  end

  it "stores a schedule declaration on the job class" do
    schedule = job_class.temporal_schedule(cron: "0 2 * * *", timezone: "America/New_York")

    assert_instance_of ActiveJob::Temporal::Schedule, schedule
    assert_same schedule, job_class.temporal_schedule
  end

  it "registers a declared schedule explicitly" do
    schedule = fake_schedule
    call_recorded_method(ActiveJob::Temporal::Schedule, :new, returns: schedule)

    job_class.temporal_schedule(cron: "0 2 * * *")

    assert_equal "schedule-handle", job_class.create_temporal_schedule
    assert_equal 1, schedule.create_count
  end

  it "registers an ad hoc schedule without storing it first" do
    schedule = fake_schedule
    schedule_calls = call_recorded_method(ActiveJob::Temporal::Schedule, :new, returns: schedule)

    result = job_class.create_temporal_schedule(cron: "0 */6 * * *", timezone: "UTC", overlap_policy: :skip)

    assert_equal "schedule-handle", result
    assert_equal [
      job_class,
      { cron: "0 */6 * * *", timezone: "UTC", overlap_policy: :skip }
    ], schedule_calls.calls_for(:new).first.arguments
  end

  it "merges declared schedule options when registering with overrides" do
    schedule = fake_schedule(
      cron: "0 2 * * *",
      timezone: "America/New_York",
      overlap_policy: :skip
    )
    schedule_calls = call_recorded_method(ActiveJob::Temporal::Schedule, :new, returns: schedule)

    job_class.temporal_schedule(cron: "0 2 * * *", timezone: "America/New_York", overlap_policy: :skip)

    job_class.create_temporal_schedule(id: "daily-report:42", args: [42])

    assert_equal [
      job_class,
      {
        cron: "0 2 * * *",
        timezone: "America/New_York",
        overlap_policy: :skip,
        id: "daily-report:42",
        args: [42]
      }
    ], schedule_calls.calls_for(:new).last.arguments
  end

  it "raises when registering without a declaration or options" do
    error = assert_raises(ArgumentError) { job_class.create_temporal_schedule }

    assert_match(/No temporal_schedule defined/, error.message)
  end

  it "raises when declaration options are not a hash" do
    error = assert_raises(ArgumentError) { job_class.temporal_schedule("daily") }

    assert_match(/temporal_schedule options must be a Hash/, error.message)
  end

  private

  def fake_schedule(**options)
    Struct.new(:options, :create_count, keyword_init: true) do
      def create
        self.create_count += 1
        "schedule-handle"
      end
    end.new(options: options, create_count: 0)
  end
end
