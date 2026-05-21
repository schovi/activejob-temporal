# frozen_string_literal: true

require "test_helper"

class JobsControllerTest < ActionDispatch::IntegrationTest
  test "enqueues a simple job" do
    post jobs_simple_url

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "enqueued", response_body["status"]
    assert_equal "SimpleJob", response_body["job_type"]
    assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.size
  end

  test "enqueues campaign email with a GlobalID subscriber" do
    subscriber = EmailSubscriber.create!(email: "ada@example.com", name: "Ada Lovelace")

    post jobs_campaign_email_url, params: { subscriber_id: subscriber.id, campaign_name: "Launch" }

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "enqueued", response_body["status"]
    assert_equal "SendCampaignEmailJob", response_body["job_type"]
    assert_equal subscriber.to_global_id.to_s, response_body["subscriber_gid"]
    assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.size
  end

  test "returns not found when no subscribed recipient exists" do
    EmailSubscriber.create!(email: "alan@example.com", name: "Alan Turing", subscribed: false)

    post jobs_campaign_email_url

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "No subscribed email subscriber found", response_body["error"]
  end
end
