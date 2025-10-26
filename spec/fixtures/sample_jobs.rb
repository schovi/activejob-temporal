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
