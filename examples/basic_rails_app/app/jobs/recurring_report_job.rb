# frozen_string_literal: true

class RecurringReportJob < ApplicationJob
  queue_as :default

  schedule cron: "0 2 * * *", timezone: "UTC", overlap_policy: :skip

  def perform
    Rails.logger.info "RecurringReportJob executed at #{Time.current}"
  end
end
