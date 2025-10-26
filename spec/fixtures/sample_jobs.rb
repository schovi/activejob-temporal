# frozen_string_literal: true

require "securerandom"

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
