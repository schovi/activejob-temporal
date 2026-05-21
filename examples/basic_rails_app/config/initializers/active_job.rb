# frozen_string_literal: true

ActiveJob::Base.queue_adapter = :temporal unless Rails.env.test?
