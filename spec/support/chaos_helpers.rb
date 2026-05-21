# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "rbconfig"
require "securerandom"
require "tempfile"
require "timeout"
require "uri"

require_relative "../fixtures/chaos_jobs"

module ChaosHelpers
  PROXIED_TEMPORAL_TARGET = ENV.fetch("TOXIPROXY_TEMPORAL_TARGET", "127.0.0.1:7234")
  TOXIPROXY_API = URI(ENV.fetch("TOXIPROXY_API", "http://127.0.0.1:8474"))
  TOXIPROXY_NAME = "temporal"

  def setup_chaos_example!
    ActiveJob::Base.queue_adapter = :temporal
    reset_chaos_event_log!
    @workflow_ids = []
  end

  def teardown_chaos_example!
    cleanup_chaos_workflows
    stop_worker_process(@worker_pid) if @worker_pid
    ActiveJob::Base.queue_adapter = @original_adapter if defined?(@original_adapter)
    ActiveJob::Temporal.configure do |config|
      config.target = TemporalTestHelper::DEFAULT_TARGET
      config.namespace = TemporalTestHelper::TEST_NAMESPACE
    end
    clear_temporal_client!
    @chaos_event_log&.unlink
  end

  def remember_original_adapter!
    @original_adapter = ActiveJob::Base.queue_adapter
  end

  def start_worker_process(task_queue, target: TemporalTestHelper::DEFAULT_TARGET)
    worker_log = chaos_worker_log_path(task_queue)
    Process.spawn(
      worker_environment(task_queue, target),
      RbConfig.ruby,
      "-Ilib",
      "-Ispec",
      "spec/support/chaos_worker.rb",
      out: worker_log,
      err: %i[child out]
    )
  end

  def start_ready_worker_process(task_queue, target: TemporalTestHelper::DEFAULT_TARGET)
    pid = start_worker_process(task_queue, target: target)
    label = "worker-ready-#{SecureRandom.hex(4)}"
    job = ChaosRecordingJob.set(queue: task_queue).perform_later(label)
    workflow_id = record_workflow_id(job)
    description = wait_for_terminal_status(workflow_id, timeout: 20)

    unless description.status == Temporalio::Client::WorkflowExecutionStatus::COMPLETED
      raise "Worker readiness workflow failed with #{description.status}"
    end

    wait_for_chaos_event("job.completed", label: label, timeout: 5)
    ChaosEventLog.clear!
    pid
  end

  def stop_worker_process(pid, signal: "TERM", timeout: 5)
    return unless pid

    Process.kill(signal, pid)
    Timeout.timeout(timeout) do
      loop do
        waited_pid = Process.wait(pid, Process::WNOHANG)
        return waited_pid if waited_pid

        sleep 0.1
      end
    end
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  rescue Timeout::Error
    Process.kill("KILL", pid)
    Process.wait(pid)
  end

  def with_temporal_target(target)
    previous_target = ActiveJob::Temporal.config.target
    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Temporal.configure { |config| config.target = target }
    reset_temporal_queue_adapter!
    yield
  ensure
    ActiveJob::Temporal.configure { |config| config.target = previous_target }
    clear_temporal_client!
    ActiveJob::Base.queue_adapter = previous_adapter
  end

  def reset_temporal_queue_adapter!
    clear_temporal_client!
    ActiveJob::Base.queue_adapter = :temporal
  end

  def record_workflow_id(job)
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)
    @workflow_ids << workflow_id
    workflow_id
  end

  def wait_for_chaos_event(type, timeout: 15, **attributes)
    wait_until(timeout: timeout) do
      events = ChaosEventLog.events_for(type, **attributes)
      events.first if events.any?
    end
  end

  def wait_until(timeout: 15)
    result = nil
    Timeout.timeout(timeout) do
      loop do
        result = yield
        return result if result

        sleep 0.1
      end
    end
  end

  def wait_for_workflow_status(workflow_id, expected_status, timeout: 20)
    wait_until(timeout: timeout) do
      description = TemporalTestHelper.client.workflow_handle(workflow_id).describe
      description if description.status == expected_status
    end
  end

  def wait_for_terminal_status(workflow_id, timeout: 30)
    wait_until(timeout: timeout) do
      description = TemporalTestHelper.client.workflow_handle(workflow_id).describe
      description if terminal_statuses.include?(description.status)
    end
  end

  def wait_for_history_event(workflow_id, event_type, timeout: 15)
    wait_until(timeout: timeout) do
      history = TemporalTestHelper.client.workflow_handle(workflow_id).fetch_history
      history.events.find { |event| event.event_type == event_type }
    end
  end

  def expect_completed_once(label)
    completed = ChaosEventLog.events_for("job.completed", label: label)
    expect(completed.size).to eq(1)
    completed.first
  end

  def ensure_temporal_proxy!
    response = toxiproxy_request(:post, "/proxies", {
                                   name: TOXIPROXY_NAME,
                                   listen: "0.0.0.0:7234",
                                   upstream: "temporal:7233",
                                   enabled: true
                                 })
    return if [201, 409].include?(response.code.to_i)

    raise "Unable to create Toxiproxy proxy: #{response.code} #{response.body}"
  end

  def with_network_partition
    update_temporal_proxy_enabled(false)
    yield
  ensure
    update_temporal_proxy_enabled(true)
  end

  def update_temporal_proxy_enabled(enabled)
    ensure_temporal_proxy!
    response = toxiproxy_request(:post, "/proxies/#{TOXIPROXY_NAME}", { enabled: enabled })
    return if response.code.to_i == 200

    raise "Unable to update Toxiproxy proxy: #{response.code} #{response.body}"
  end

  private

  def reset_chaos_event_log!
    @chaos_event_log = Tempfile.new(["activejob-temporal-chaos", ".jsonl"])
    @chaos_event_log.close
    ENV["CHAOS_EVENT_LOG"] = @chaos_event_log.path
    ChaosEventLog.clear!
  end

  def chaos_worker_log_path(task_queue)
    FileUtils.mkdir_p("tmp/chaos")
    File.join("tmp/chaos", "#{task_queue}.log")
  end

  def worker_environment(task_queue, target)
    {
      "ACTIVEJOB_TEMPORAL_TASK_QUEUE" => task_queue,
      "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__),
      "CHAOS_EVENT_LOG" => ENV.fetch("CHAOS_EVENT_LOG"),
      "TEMPORAL_TEST_TARGET" => target
    }
  end

  def clear_temporal_client!
    ActiveJob::Temporal.instance_variable_set(:@client, nil)
  end

  def terminal_statuses
    [
      Temporalio::Client::WorkflowExecutionStatus::COMPLETED,
      Temporalio::Client::WorkflowExecutionStatus::FAILED,
      Temporalio::Client::WorkflowExecutionStatus::CANCELED,
      Temporalio::Client::WorkflowExecutionStatus::TERMINATED,
      Temporalio::Client::WorkflowExecutionStatus::CONTINUED_AS_NEW,
      Temporalio::Client::WorkflowExecutionStatus::TIMED_OUT
    ]
  end

  def cleanup_chaos_workflows
    Array(@workflow_ids).each do |workflow_id|
      handle = TemporalTestHelper.client.workflow_handle(workflow_id)
      handle.terminate("ActiveJob::Temporal chaos spec cleanup") if running?(handle)
    rescue StandardError
      nil
    end
  end

  def running?(handle)
    handle.describe.status == Temporalio::Client::WorkflowExecutionStatus::RUNNING
  end

  def toxiproxy_request(method, path, body = nil)
    uri = TOXIPROXY_API + path
    request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    if body
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
    end
    Net::HTTP.start(uri.hostname, uri.port, read_timeout: 5, open_timeout: 5) do |http|
      http.request(request)
    end
  rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout => e
    raise "Toxiproxy is required for chaos network specs at #{TOXIPROXY_API}: #{e.message}"
  end
end
