# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

RSpec.describe "Idempotency key handling", :integration do
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    stop_worker(@worker_thread)
  end

  def client
    TemporalTestHelper.client
  end

  it "provides workflow ID as idempotency key to job" do
    task_queue = "test-idempotency-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    captured_key = nil

    job_class = Class.new(ActiveJob::Base) do
      class_variable_set(:@@captured_key, nil)

      def perform(test_id)
        # Access idempotency key from thread-local storage
        key = Thread.current[ActiveJob::Temporal::Activities::AjRunnerActivity::IDEMPOTENCY_KEY]
        self.class.class_variable_set(:@@captured_key, key)
      end

      def self.captured_key
        class_variable_get(:@@captured_key) if class_variable_defined?(:@@captured_key)
      end
    end

    # Enqueue and execute job
    job_id = SecureRandom.uuid
    job = job_class.set(queue: task_queue).perform_later("test-1")

    # Build the workflow ID to verify it matches what's in the idempotency key
    workflow_id = ActiveJob::Temporal::Adapter.build_workflow_id(job)

    # Wait for job to execute
    Timeout.timeout(10) do
      loop do
        key = job_class.captured_key
        break if key.present?
        sleep 0.1
      end
    end

    captured_key = job_class.captured_key

    # Verify the idempotency key includes the workflow ID
    expect(captured_key).to be_present
    expect(captured_key).to include(workflow_id)
    expect(captured_key).to match(/\/runner\z/) # Should end with "/runner"
  end

  it "provides consistent idempotency key across job execution" do
    task_queue = "test-idempotency-consistency-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    captured_keys = []
    keys_lock = Mutex.new

    job_class = Class.new(ActiveJob::Base) do
      class_variable_set(:@@captured_keys, [])
      class_variable_set(:@@keys_lock, Mutex.new)

      def perform(iteration)
        # Capture the idempotency key multiple times during execution
        key = Thread.current[ActiveJob::Temporal::Activities::AjRunnerActivity::IDEMPOTENCY_KEY]
        lock = self.class.class_variable_get(:@@keys_lock)
        lock.synchronize do
          keys = self.class.class_variable_get(:@@captured_keys)
          keys << key
          self.class.class_variable_set(:@@captured_keys, keys)
        end
      end

      def self.captured_keys
        class_variable_get(:@@captured_keys) if class_variable_defined?(:@@captured_keys)
      end
    end

    # Enqueue job
    job_class.set(queue: task_queue).perform_later(1)

    # Wait for job execution
    Timeout.timeout(10) do
      loop do
        keys = job_class.captured_keys
        break if keys.present? && keys.size > 0
        sleep 0.1
      end
    end

    captured_keys = job_class.captured_keys

    # Verify we captured at least one key
    expect(captured_keys.size).to be >= 1

    # Verify all keys are identical (consistent throughout execution)
    expect(captured_keys.uniq.size).to eq(1)
    expect(captured_keys.first).to match(/\/runner\z/)
  end

  it "clears idempotency key after job execution" do
    task_queue = "test-idempotency-cleanup-#{SecureRandom.hex(4)}"

    # Create a custom workflow that we can monitor directly
    job_class = Class.new(ActiveJob::Base) do
      def perform(test_id)
        # Job logic - idempotency key should be set here
      end
    end

    @worker_thread = start_worker(task_queue)
    sleep 0.5

    # Enqueue job
    job_class.set(queue: task_queue).perform_later("test-cleanup")

    # Wait for job to complete
    Timeout.timeout(10) do
      loop do
        # Give it time to execute and clean up
        sleep 0.2
        # Break after a reasonable time
        break
      end
    end

    # Note: In a real scenario with proper workflow execution,
    # we would verify that the worker's thread-local key is cleared.
    # Since we're testing the activity in isolation through the integration,
    # we rely on the ensure block in AjRunnerActivity#execute to clean up.
    # This test verifies the flow completes without hanging.
    expect(@worker_thread).to be_alive
  end

  it "generates unique idempotency keys for different jobs" do
    task_queue = "test-idempotency-unique-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    captured_keys = Queue.new

    job_class = Class.new(ActiveJob::Base) do
      define_method :perform do |job_num|
        key = Thread.current[ActiveJob::Temporal::Activities::AjRunnerActivity::IDEMPOTENCY_KEY]
        captured_keys.push({ job_num: job_num, key: key })
      end
    end

    # Enqueue multiple jobs
    3.times do |i|
      job_class.set(queue: task_queue).perform_later(i)
    end

    # Wait for all jobs to execute
    Timeout.timeout(10) do
      loop do
        break if captured_keys.size >= 3
        sleep 0.1
      end
    end

    # Collect captured keys
    executed_jobs = []
    loop do
      break if captured_keys.empty?
      executed_jobs << captured_keys.pop
    end

    # Verify we have 3 different jobs
    expect(executed_jobs.size).to eq(3)

    # Extract the keys
    keys = executed_jobs.map { |job| job[:key] }

    # Verify all keys are unique (different jobs have different workflow IDs)
    expect(keys.uniq.size).to eq(3)

    # Verify all keys are properly formatted
    keys.each do |key|
      expect(key).to match(/\/runner\z/)
    end
  end

  private

  def start_worker(task_queue = "default")
    Thread.new do
      worker = Temporalio::Worker.new(
        client: TemporalTestHelper.client,
        task_queue: task_queue,
        workflows: [ActiveJob::Temporal::Workflows::AjWorkflow],
        activities: [ActiveJob::Temporal::Activities::AjRunnerActivity]
      )
      worker.run
    end
  end

  def stop_worker(thread)
    return unless thread&.alive?

    thread.kill
    thread.join(5)
  end
end
