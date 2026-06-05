# frozen_string_literal: true

require "spec_helper"
require "active_job"

describe "ActiveJob Temporal job dependencies" do
  let(:queue_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
  let(:parent_job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "DependencyParentJob"

      def perform = nil
    end
  end
  let(:child_job_class) do
    Class.new(ActiveJob::Base) do
      def self.name = "DependencyChildJob"

      def perform = nil
    end
  end

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    original_workflow_id_generator = ActiveJob::Temporal.config.workflow_id_generator
    ActiveJob::Base.queue_adapter = queue_adapter

    example.run
  ensure
    ActiveJob::Temporal.config.workflow_id_generator = original_workflow_id_generator
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "captures an enqueued job instance dependency" do
    parent_job = parent_job_class.new
    parent_job.job_id = "parent-123"

    job = child_job_class.set(depends_on: parent_job).perform_later
    expected_dependencies = [
      {
        job_class: "DependencyParentJob",
        job_id: "parent-123",
        workflow_id: "ajwf:DependencyParentJob:parent-123"
      }
    ]

    assert_equal expected_dependencies, job.temporal_dependencies
    assert_equal :fail, job.temporal_dependency_failure_policy
    assert_equal 1, queue_adapter.enqueued_jobs.size
  end

  it "captures configured workflow IDs for enqueued job instance dependencies" do
    ActiveJob::Temporal.config.workflow_id_generator = ->(job) { "tenant-42:#{job.class.name}:#{job.job_id}" }
    parent_job = parent_job_class.new
    parent_job.job_id = "parent-123"

    job = child_job_class.set(depends_on: parent_job).perform_later
    expected_dependencies = [
      {
        job_class: "DependencyParentJob",
        job_id: "parent-123",
        workflow_id: "tenant-42:DependencyParentJob:parent-123"
      }
    ]

    assert_equal expected_dependencies, job.temporal_dependencies
  end

  it "captures job ID dependencies with an explicit failure policy" do
    job = child_job_class.set(depends_on: %w[parent-123 parent-456], on_dependency_failure: :ignore).perform_later
    expected_dependencies = [
      { job_id: "parent-123" },
      { job_id: "parent-456" }
    ]

    assert_equal expected_dependencies, job.temporal_dependencies
    assert_equal :ignore, job.temporal_dependency_failure_policy
  end

  it "captures dependency wait options" do
    job = child_job_class.set(
      depends_on: "parent-123",
      dependency_wait: {
        timeout: 5.minutes,
        initial_interval: 5.seconds,
        max_interval: 30.seconds,
        backoff: 3.0
      }
    ).perform_later
    expected_wait = {
      timeout: 300.0,
      initial_interval: 5.0,
      max_interval: 30.0,
      backoff: 3.0
    }

    assert_equal expected_wait, job.temporal_dependency_wait
  end

  it "captures explicit dependency hashes" do
    job = child_job_class.set(
      depends_on: [
        { job_class: parent_job_class, job_id: "parent-123" },
        { workflow_id: "custom-workflow-id" }
      ]
    ).perform_later
    expected_dependencies = [
      {
        job_class: "DependencyParentJob",
        job_id: "parent-123"
      },
      {
        workflow_id: "custom-workflow-id"
      }
    ]

    assert_equal expected_dependencies, job.temporal_dependencies
  end

  it "captures a single explicit dependency hash" do
    job = child_job_class.set(depends_on: { job_class: parent_job_class, job_id: "parent-123" }).perform_later
    expected_dependencies = [
      {
        job_class: "DependencyParentJob",
        job_id: "parent-123"
      }
    ]

    assert_equal expected_dependencies, job.temporal_dependencies
  end

  it "captures exact dependency run IDs" do
    job = child_job_class.set(
      depends_on: {
        workflow_id: "ajwf:DependencyParentJob:parent-123",
        run_id: "run-123"
      }
    ).perform_later
    expected_dependencies = [
      {
        workflow_id: "ajwf:DependencyParentJob:parent-123",
        run_id: "run-123"
      }
    ]

    assert_equal expected_dependencies, job.temporal_dependencies
  end

  it "preserves standard ActiveJob set options" do
    job = child_job_class.set(depends_on: "parent-123", queue: "critical", priority: 10).perform_later

    assert_equal "critical", job.queue_name
    assert_equal 10, job.priority
  end

  it "rejects an empty dependency list" do
    error = assert_raises(ArgumentError) { child_job_class.new.set(depends_on: []) }
    assert_match(/must contain at least one/, error.message)
  end

  it "rejects unsupported dependency entries" do
    error = assert_raises(ArgumentError) { child_job_class.new.set(depends_on: [Object.new]) }
    assert_match(/ActiveJob instances, job IDs, or dependency hashes/, error.message)
  end

  it "rejects dependency hashes without identifiers" do
    error = assert_raises(ArgumentError) { child_job_class.new.set(depends_on: [{ job_class: parent_job_class }]) }
    assert_match(/must include job_id or workflow_id/, error.message)
  end

  it "rejects invalid failure policies" do
    error = assert_raises(ArgumentError) do
      child_job_class.new.set(depends_on: "parent-123", on_dependency_failure: :retry)
    end
    assert_match(/must be :fail or :ignore/, error.message)
  end

  it "rejects invalid dependency wait options" do
    error = assert_raises(ArgumentError) do
      child_job_class.new.set(depends_on: "parent-123", dependency_wait: { timeout: 0 })
    end
    assert_match(/dependency_wait timeout must be positive/, error.message)
  end

  it "rejects failure policy configuration without dependencies" do
    error = assert_raises(ArgumentError) { child_job_class.new.set(on_dependency_failure: :ignore) }
    assert_match(/requires depends_on/, error.message)
  end

  it "rejects dependency wait configuration without dependencies" do
    error = assert_raises(ArgumentError) { child_job_class.new.set(dependency_wait: { timeout: 1.minute }) }
    assert_match(/dependency_wait requires depends_on/, error.message)
  end
end
