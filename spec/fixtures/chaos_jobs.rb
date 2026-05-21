# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require "active_job"
require "active_support/core_ext/numeric/time"
require "temporalio/activity"

module ChaosEventLog
  module_function

  def path
    ENV.fetch("CHAOS_EVENT_LOG")
  end

  def clear!
    File.write(path, "")
  end

  def events
    return [] unless File.exist?(path)

    File.readlines(path, chomp: true).filter_map do |line|
      JSON.parse(line, symbolize_names: true) unless line.empty?
    end
  end

  def events_for(type, **attributes)
    events.select do |event|
      event[:type] == type.to_s && attributes.all? { |key, value| event[key] == value }
    end
  end

  def record(type, attributes = {})
    append_event(type, attributes)
  end

  def append_event(type, attributes)
    with_locked_file { |file| append_event_to(file, type, attributes) }
  end
  private_class_method :append_event

  def append_event_to(file, type, attributes)
    file.seek(0, IO::SEEK_END)
    file.write(JSON.generate(attributes.merge(type: type.to_s, recorded_at: Time.now.utc.iso8601)))
    file.write("\n")
    file.flush
  end
  private_class_method :append_event_to

  def with_locked_file
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, File::RDWR | File::CREAT, 0o644) do |file|
      file.flock(File::LOCK_EX)
      yield file
    ensure
      file.flock(File::LOCK_UN)
    end
  end
  private_class_method :with_locked_file
end

class ChaosRecordingJob < ActiveJob::Base
  queue_as :default

  def perform(label)
    idempotency_key = Thread.current[ActiveJob::Temporal::Activities::AjRunnerActivity::IDEMPOTENCY_KEY]
    ChaosEventLog.record(
      "job.completed",
      job_class: self.class.name,
      label: label,
      idempotency_key: idempotency_key
    )
  end
end

class ChaosScheduledJob < ChaosRecordingJob
end

class ChaosLongRunningJob < ActiveJob::Base
  retry_on StandardError, wait: 1.second, attempts: 3
  temporal_options(
    start_to_close_timeout: 20.seconds,
    heartbeat_timeout: 2.seconds,
    schedule_to_close_timeout: 45.seconds
  )
  queue_as :default

  def perform(label, duration = 4.0)
    idempotency_key = Thread.current[ActiveJob::Temporal::Activities::AjRunnerActivity::IDEMPOTENCY_KEY]
    ChaosEventLog.record("activity.started", job_class: self.class.name, label: label, idempotency_key: idempotency_key)

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + duration.to_f
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      Temporalio::Activity::Context.current.heartbeat
      ChaosEventLog.record(
        "activity.heartbeat",
        job_class: self.class.name,
        label: label,
        idempotency_key: idempotency_key
      )
      sleep 0.5
    end

    ChaosEventLog.record(
      "job.completed",
      job_class: self.class.name,
      label: label,
      idempotency_key: idempotency_key
    )
  end
end
