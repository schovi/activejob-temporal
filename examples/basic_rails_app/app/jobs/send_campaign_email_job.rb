# frozen_string_literal: true

class SendCampaignEmailJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(email_subscriber, campaign_name:)
    unless email_subscriber.subscribed?
      Rails.logger.info "Skipping unsubscribed recipient #{email_subscriber.email}"
      return
    end

    email_subscriber.update!(
      last_campaign_name: campaign_name,
      last_campaign_sent_at: Time.current
    )

    Rails.logger.info "Sent #{campaign_name} campaign email to #{email_subscriber.email}"
  end
end
