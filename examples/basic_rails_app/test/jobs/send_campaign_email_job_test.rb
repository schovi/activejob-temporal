# frozen_string_literal: true

require "test_helper"

class SendCampaignEmailJobTest < ActiveJob::TestCase
  test "uses GlobalID serialization for email subscriber arguments" do
    subscriber = EmailSubscriber.create!(email: "ada@example.com", name: "Ada Lovelace")

    serialized_arguments = ActiveJob::Arguments.serialize([subscriber])

    assert_equal subscriber.to_global_id.to_s, serialized_arguments.first["_aj_globalid"]
  end

  test "records the campaign delivery on subscribed recipients" do
    subscriber = EmailSubscriber.create!(email: "ada@example.com", name: "Ada Lovelace")

    SendCampaignEmailJob.perform_now(subscriber, campaign_name: "Launch")

    subscriber.reload
    assert_equal "Launch", subscriber.last_campaign_name
    assert_predicate subscriber.last_campaign_sent_at, :present?
  end

  test "skips unsubscribed recipients" do
    subscriber = EmailSubscriber.create!(email: "alan@example.com", name: "Alan Turing", subscribed: false)

    SendCampaignEmailJob.perform_now(subscriber, campaign_name: "Launch")

    subscriber.reload
    assert_nil subscriber.last_campaign_name
    assert_nil subscriber.last_campaign_sent_at
  end
end
