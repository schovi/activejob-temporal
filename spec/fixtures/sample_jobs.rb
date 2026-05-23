# frozen_string_literal: true

require "securerandom"
require "active_job"
require "active_support/core_ext/numeric/time"

ActiveJob::Base.queue_adapter = :test

unless defined?(ApplicationJob)
  class ApplicationJob
    attr_accessor :job_id, :queue_name, :executions, :exception_executions
    attr_reader :arguments

    def initialize(arguments = [])
      @job_id = SecureRandom.uuid
      @queue_name = "default"
      @arguments = arguments
      @executions = 0
      @exception_executions = {}
    end
  end
end

class SimpleJob < ApplicationJob
end

class ScheduledJob < ApplicationJob
end

class SampleJobError < StandardError; end
class SecondarySampleError < SampleJobError; end
class FatalJobError < StandardError; end
class DerivedFatalJobError < FatalJobError; end
class NetworkTimeoutError < StandardError; end

class RetryableJob < ActiveJob::Base
  retry_on SampleJobError, wait: 60.seconds, attempts: 5
end

class DiscardableJob < ActiveJob::Base
  retry_on SampleJobError, wait: 45.seconds, attempts: 3
  discard_on FatalJobError
end

class DiscardOnlyJob < ActiveJob::Base
  discard_on FatalJobError
end

class MultiRetryJob < ActiveJob::Base
  retry_on StandardError, wait: 40.seconds, attempts: 2
  retry_on SecondarySampleError, wait: 10.seconds, attempts: 6
end

class UnlimitedRetryJob < ActiveJob::Base
  retry_on SampleJobError, attempts: :unlimited
end

class ProcWaitRetryJob < ActiveJob::Base
  retry_on SampleJobError, wait: ->(_executions) { 15.seconds }
end

class SymbolWaitRetryJob < ActiveJob::Base
  retry_on SampleJobError, wait: :custom_wait
end

class ExponentiallyLongerRetryJob < ActiveJob::Base
  retry_on SampleJobError, wait: :exponentially_longer, attempts: 5
end

class PolynomiallyLongerRetryJob < ActiveJob::Base
  retry_on SampleJobError, wait: :polynomially_longer, attempts: 6
end

class InvalidAttemptsJob < ActiveJob::Base
  retry_on SampleJobError, attempts: "five"
end

class ExternalConstantRetryJob < ActiveJob::Base
  retry_on "NetworkTimeoutError", wait: 15.seconds, attempts: 2
end

class TestJob < ActiveJob::Base
  class << self
    attr_accessor :last_argument
  end

  queue_as :default

  def perform(arg)
    self.class.last_argument = arg
  end
end

class RetryTestJob < ActiveJob::Base
  retry_on StandardError, wait: 1, attempts: 3

  queue_as :default

  def perform
    state = TestState.instance
    state.attempt_count += 1
    raise StandardError, "Transient error" if state.attempt_count == 1

    state.test_result = "success"
  end
end

class NonRetryableTestError < StandardError; end

class DiscardTestJob < ActiveJob::Base
  discard_on NonRetryableTestError

  queue_as :default

  def perform
    TestState.instance.discard_test_executed = true
    raise NonRetryableTestError, "This error should not be retried"
  end
end

class LongRunningJob < ActiveJob::Base
  queue_as :default

  def perform
    state = TestState.instance
    state.long_running_iterations = 0
    state.long_running_completed = false

    10.times do
      Temporalio::Activity::Context.current.heartbeat
      sleep 1
      state.long_running_iterations += 1
    end

    state.long_running_completed = true
  end
end

class CustomTimeoutJob < ActiveJob::Base
  temporal_options(
    start_to_close_timeout: 2.minutes,
    heartbeat_timeout: 10.seconds
  )

  queue_as :default

  def perform
    TestState.instance.custom_timeout_executed = true
  end
end
