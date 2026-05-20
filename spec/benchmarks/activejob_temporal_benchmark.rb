# frozen_string_literal: true

require "bundler/setup"
require "benchmark/ips"
require "logger"
require "activejob/temporal"

class BenchmarkTransientError < StandardError; end
class BenchmarkFatalError < StandardError; end

class BenchmarkJob < ActiveJob::Base
  retry_on BenchmarkTransientError, wait: 5.seconds, attempts: 3
  discard_on BenchmarkFatalError

  queue_as :default

  def perform(_payload); end
end

class BenchmarkClient
  # Temporal client compatibility requires this method name.
  # rubocop:disable Naming/PredicateMethod
  def start_workflow(_workflow_class, _payload, **_options)
    true
  end
  # rubocop:enable Naming/PredicateMethod
end

ActiveJob::Base.queue_adapter = :test

ActiveJob::Temporal.configure do |config|
  config.logger = Logger.new(nil)
  config.default_retry_initial_interval = 30.seconds
  config.default_retry_backoff = 2.0
  config.default_retry_max_attempts = 1
end

payload_argument = {
  account_id: 123,
  invoice_ids: (1..20).to_a,
  metadata: {
    source: "benchmark",
    requested_by: "activejob-temporal"
  }
}

job = BenchmarkJob.new(payload_argument)
workflow_id_builder = ActiveJob::Temporal::WorkflowIdBuilder.new
enqueuer = ActiveJob::Temporal::WorkflowEnqueuer.new(
  BenchmarkClient.new,
  ActiveJob::Temporal.config,
  ActiveJob::Temporal.config.logger,
  workflow_id_builder: workflow_id_builder
)
retry_exception = BenchmarkTransientError.new("temporary failure")

Benchmark.ips do |benchmark|
  benchmark.config(
    time: Integer(ENV.fetch("BENCHMARK_TIME", "5")),
    warmup: Integer(ENV.fetch("BENCHMARK_WARMUP", "2"))
  )

  benchmark.report("enqueue job") do
    enqueuer.enqueue(job)
  end

  benchmark.report("build payload") do
    ActiveJob::Temporal::Payload.from_job(job)
  end

  benchmark.report("config access") do
    ActiveJob::Temporal.config.target
  end

  benchmark.report("workflow id generation") do
    workflow_id_builder.build(job)
  end

  benchmark.report("retry policy calculation") do
    ActiveJob::Temporal::RetryMapper.for(BenchmarkJob, retry_exception)
  end

  benchmark.compare!
end
