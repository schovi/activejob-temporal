# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class JobsControllerTest < ActionDispatch::IntegrationTest
  test "enqueues a simple job" do
    post jobs_simple_url

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "enqueued", response_body["status"]
    assert_equal "SimpleJob", response_body["job_type"]
    assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.size
  end

  test "enqueues retryable jobs with a stable attempt key" do
    post jobs_retryable_url, params: { should_fail: "true" }

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "enqueued", response_body["status"]
    assert_equal "RetryableJob", response_body["job_type"]
    assert_match(/\A[0-9a-f-]{36}\z/, response_body["attempt_key"])
    assert_equal response_body["attempt_key"], ActiveJob::Base.queue_adapter.enqueued_jobs.last["arguments"].last["attempt_key"]
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

  test "cancels a valid job class with the class constant" do
    cancelled = nil
    job_id = "550e8400-e29b-41d4-a716-446655440000"

    ActiveJob::Temporal.stub(:cancel, ->(job_class, received_job_id) { cancelled = [job_class, received_job_id] }) do
      delete jobs_cancel_url, params: { job_class: "CancellableJob", job_id: job_id }
    end

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "cancelled", response_body["status"]
    assert_equal "CancellableJob", response_body["job_class"]
    assert_equal [CancellableJob, job_id], cancelled
  end

  test "rejects invalid cancellation job classes" do
    delete jobs_cancel_url, params: { job_class: "Kernel", job_id: "550e8400-e29b-41d4-a716-446655440000" }

    assert_response :bad_request
    response_body = JSON.parse(response.body)
    assert_equal "Invalid job class", response_body["error"]
  end
end
