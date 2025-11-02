# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "securerandom"
require "temporalio/worker"
require_relative "../fixtures/sample_jobs"

RSpec.describe "Concurrent worker execution", :integration do
  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :temporal

    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    stop_all_workers
  end

  def client
    TemporalTestHelper.client
  end

  it "prevents duplicate execution from concurrent workers" do
    task_queue = "test-concurrent-#{SecureRandom.hex(4)}"
    Mutex.new

    # Create a job class that tracks execution count
    job_class = Class.new(ActiveJob::Base) do
      @execution_count = 0
      @execution_lock = Mutex.new

      class << self
        attr_accessor :execution_count, :execution_lock
      end

      def perform(_test_id)
        self.class.execution_lock.synchronize do
          self.class.execution_count += 1
        end
        sleep 0.2 # Simulate work
      end

      def self.reset_count
        @execution_count = 0
      end
    end

    # Start two workers
    worker1 = start_worker(task_queue)
    worker2 = start_worker(task_queue)
    sleep 0.5

    # Enqueue a single job
    test_id = SecureRandom.uuid
    job_class.set(queue: task_queue).perform_later(test_id)

    # Wait for job to execute
    Timeout.timeout(10) do
      loop do
        count = job_class.execution_count
        break if count.present? && count > 0

        sleep 0.1
      end
    end

    # Give some time for any duplicate execution
    sleep 0.5

    # Verify job executed exactly once
    expect(job_class.execution_count).to eq(1)

    @worker_threads = [worker1, worker2]
  end

  it "handles concurrent job enqueuing from multiple threads" do
    task_queue = "test-concurrent-enqueue-#{SecureRandom.hex(4)}"
    @worker_thread = start_worker(task_queue)
    sleep 0.5

    completed_jobs = Queue.new
    job_class = Class.new(ActiveJob::Base) do
      define_method :perform do |job_num|
        completed_jobs.push(job_num)
      end
    end

    # Enqueue jobs from multiple threads
    threads = 5.times.map do |i|
      Thread.new(i) do |job_num|
        job_class.set(queue: task_queue).perform_later(job_num)
      end
    end

    # Wait for all enqueue calls to complete
    threads.each(&:join)

    # Wait for all jobs to execute
    Timeout.timeout(10) do
      loop do
        break if completed_jobs.size >= 5

        sleep 0.1
      end
    end

    # Collect all executed job numbers
    executed_jobs = []
    loop do
      break if completed_jobs.empty?

      executed_jobs << completed_jobs.pop
    end

    # Verify all 5 jobs executed
    expect(executed_jobs.sort).to eq([0, 1, 2, 3, 4])
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

  def stop_all_workers
    [@worker_thread, @worker_threads].flatten.compact.each do |thread|
      next unless thread&.alive?

      thread.kill
      thread.join(5)
    end
  end
end
