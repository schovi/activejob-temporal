# frozen_string_literal: true

# JobsController provides API endpoints to enqueue and manage jobs
class JobsController < ApplicationController
  # POST /jobs/simple
  # Enqueues a simple job that executes immediately
  def simple
    job = SimpleJob.perform_later("Hello from Simple Job at #{Time.current}")

    render json: {
      status: "enqueued",
      job_type: "SimpleJob",
      job_id: job.job_id,
      queue: job.queue_name,
      message: "Job enqueued successfully"
    }
  end

  # POST /jobs/scheduled
  # Enqueues a job to be executed after a delay
  # Query params: delay (in seconds, default: 30)
  def scheduled
    delay = params[:delay]&.to_i || 30
    scheduled_at = Time.current + delay.seconds

    job = ScheduledJob.set(wait: delay.seconds).perform_later(
      "Hello from Scheduled Job",
      scheduled_at.to_s
    )

    render json: {
      status: "scheduled",
      job_type: "ScheduledJob",
      job_id: job.job_id,
      queue: job.queue_name,
      delay_seconds: delay,
      scheduled_at: scheduled_at,
      message: "Job scheduled to run in #{delay} seconds"
    }
  end

  # POST /jobs/retryable
  # Enqueues a job that demonstrates retry behavior
  # Query params: should_fail (true/false, default: false)
  def retryable
    should_fail = params[:should_fail] == "true"

    job = RetryableJob.perform_later(
      "Hello from Retryable Job at #{Time.current}",
      should_fail: should_fail
    )

    render json: {
      status: "enqueued",
      job_type: "RetryableJob",
      job_id: job.job_id,
      queue: job.queue_name,
      will_fail: should_fail,
      message: should_fail ? "Job will fail and retry up to 5 times" : "Job will execute successfully"
    }
  end

  # POST /jobs/cancellable
  # Enqueues a long-running job that can be cancelled
  # Query params: iterations (default: 10)
  def cancellable
    iterations = params[:iterations]&.to_i || 10

    job = CancellableJob.perform_later(iterations)

    render json: {
      status: "enqueued",
      job_type: "CancellableJob",
      job_id: job.job_id,
      queue: job.queue_name,
      iterations: iterations,
      estimated_duration: "#{iterations * 2} seconds",
      message: "Long-running job enqueued. Use DELETE /jobs/cancel with job_id to cancel it."
    }
  end

  def campaign_email
    subscriber = find_campaign_subscriber

    return render json: { error: "No subscribed email subscriber found" }, status: :not_found unless subscriber

    campaign_name = params[:campaign_name].presence || "Spring Launch"
    job = SendCampaignEmailJob.perform_later(subscriber, campaign_name: campaign_name)

    render json: {
      status: "enqueued",
      job_type: "SendCampaignEmailJob",
      job_id: job.job_id,
      queue: job.queue_name,
      subscriber_id: subscriber.id,
      subscriber_gid: subscriber.to_global_id.to_s,
      campaign_name: campaign_name,
      message: "Campaign email job enqueued with a GlobalID subscriber argument"
    }
  end

  # DELETE /jobs/cancel
  # Cancels a running or pending job
  # Required params: job_class, job_id
  def cancel
    job_class = params[:job_class]
    job_id = params[:job_id]

    if job_class.blank? || job_id.blank?
      return render json: {
        error: "Missing required parameters",
        message: "Both job_class and job_id are required"
      }, status: :bad_request
    end

    # Validate job class
    unless valid_job_class?(job_class)
      return render json: {
        error: "Invalid job class",
        message: "Job class must be one of: SimpleJob, ScheduledJob, RetryableJob, CancellableJob, SendCampaignEmailJob"
      }, status: :bad_request
    end

    begin
      ActiveJob::Temporal.cancel(job_class, job_id)

      render json: {
        status: "cancelled",
        job_class: job_class,
        job_id: job_id,
        message: "Cancellation request sent. The job will stop at the next heartbeat."
      }
    rescue StandardError => e
      render json: {
        error: "Cancellation failed",
        message: e.message
      }, status: :internal_server_error
    end
  end

  private

  def find_campaign_subscriber
    if params[:subscriber_id].present?
      EmailSubscriber.subscribed.find_by(id: params[:subscriber_id])
    else
      EmailSubscriber.subscribed.first
    end
  end

  def valid_job_class?(job_class)
    %w[SimpleJob ScheduledJob RetryableJob CancellableJob SendCampaignEmailJob].include?(job_class)
  end
end
