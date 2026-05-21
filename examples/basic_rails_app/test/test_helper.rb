# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"

ActiveJob::Base.queue_adapter = :test

class ActiveSupport::TestCase
  parallelize(workers: :number_of_processors)

  setup do
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ActiveJob::Base.queue_adapter.performed_jobs.clear
    EmailSubscriber.delete_all
  end
end
