# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

class RateLimitedIntegrationJob < ActiveJob::Base
  rate_limit 1, per: :second

  queue_as :default

  def perform(value)
    TestState.instance.test_result = value
  end
end

class RecordingRateLimiter
  attr_reader :calls

  def initialize(wait_times)
    @wait_times = wait_times
    @calls = []
    @mutex = Mutex.new
  end

  def wait_time_for(rate_limits)
    @mutex.synchronize do
      @calls << rate_limits.map do |rate_limit|
        ActiveJob::Temporal::RateLimitOptions.normalize_hash(rate_limit).transform_keys(&:to_s)
      end
      @wait_times.shift || 0.0
    end
  end
end

RSpec.describe "Rate limiting", :integration do
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    original_rate_limiter = ActiveJob::Temporal.config.rate_limiter
    original_global_rate_limit = ActiveJob::Temporal.config.global_rate_limit

    ActiveJob::Base.queue_adapter = :temporal
    TestState.instance.reset!

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    ActiveJob::Temporal.configure do |config|
      config.rate_limiter = original_rate_limiter
      config.global_rate_limit = original_global_rate_limit
    end
    stop_worker(@worker_thread)
    TestState.instance.reset!
  end

  it "checks global and per-job limits before performing the job" do
    limiter = RecordingRateLimiter.new([0.0])
    ActiveJob::Temporal.configure do |config|
      config.rate_limiter = limiter
      config.global_rate_limit = { limit: 10, per: :minute }
    end
    task_queue = "test-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    RateLimitedIntegrationJob.set(queue: task_queue).perform_later("limited")

    Timeout.timeout(10) do
      loop do
        break if TestState.instance.test_result == "limited"

        sleep 0.1
      end
    end

    expect(limiter.calls).to eq([
                                  [
                                    { "limit" => 10, "interval" => 60.0, "key" => "activejob-temporal:global" },
                                    {
                                      "limit" => 1,
                                      "interval" => 1.0,
                                      "key" => "activejob-temporal:job:RateLimitedIntegrationJob"
                                    }
                                  ]
                                ])
  ensure
    stop_worker(@worker_thread)
  end

  private

  def start_worker(task_queue)
    Thread.new do
      worker = Temporalio::Worker.new(
        client: TemporalTestHelper.client,
        task_queue: task_queue,
        workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
        activities: [
          ActiveJob::Temporal::Activities::RateLimitActivity,
          ActiveJob::Temporal::Activities::AjRunnerActivity
        ]
      )
      worker.run
    end
  end

  def stop_worker(thread)
    return unless thread&.alive?

    thread.kill
    thread.join(5)
  end
end
