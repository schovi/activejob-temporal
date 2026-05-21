# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe "ActiveJob Temporal job dependencies" do
  let(:test_adapter) { ActiveJob::QueueAdapters::TestAdapter.new }
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
    ActiveJob::Base.queue_adapter = test_adapter

    example.run
  ensure
    ActiveJob::Temporal.config.workflow_id_generator = original_workflow_id_generator
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "captures an enqueued job instance dependency" do
    parent_job = parent_job_class.new
    parent_job.job_id = "parent-123"

    job = child_job_class.set(depends_on: parent_job).perform_later

    expect(job.temporal_dependencies).to eq([
                                              {
                                                job_class: "DependencyParentJob",
                                                job_id: "parent-123",
                                                workflow_id: "ajwf:DependencyParentJob:parent-123"
                                              }
                                            ])
    expect(job.temporal_dependency_failure_policy).to eq(:fail)
    expect(test_adapter.enqueued_jobs.size).to eq(1)
  end

  it "captures configured workflow IDs for enqueued job instance dependencies" do
    ActiveJob::Temporal.config.workflow_id_generator = ->(job) { "tenant-42:#{job.class.name}:#{job.job_id}" }
    parent_job = parent_job_class.new
    parent_job.job_id = "parent-123"

    job = child_job_class.set(depends_on: parent_job).perform_later

    expect(job.temporal_dependencies).to eq([
                                              {
                                                job_class: "DependencyParentJob",
                                                job_id: "parent-123",
                                                workflow_id: "tenant-42:DependencyParentJob:parent-123"
                                              }
                                            ])
  end

  it "captures job ID dependencies with an explicit failure policy" do
    job = child_job_class.set(depends_on: %w[parent-123 parent-456], on_dependency_failure: :ignore).perform_later

    expect(job.temporal_dependencies).to eq([
                                              { job_id: "parent-123" },
                                              { job_id: "parent-456" }
                                            ])
    expect(job.temporal_dependency_failure_policy).to eq(:ignore)
  end

  it "captures explicit dependency hashes" do
    job = child_job_class.set(
      depends_on: [
        { job_class: parent_job_class, job_id: "parent-123" },
        { workflow_id: "custom-workflow-id" }
      ]
    ).perform_later

    expect(job.temporal_dependencies).to eq([
                                              {
                                                job_class: "DependencyParentJob",
                                                job_id: "parent-123"
                                              },
                                              {
                                                workflow_id: "custom-workflow-id"
                                              }
                                            ])
  end

  it "captures a single explicit dependency hash" do
    job = child_job_class.set(depends_on: { job_class: parent_job_class, job_id: "parent-123" }).perform_later

    expect(job.temporal_dependencies).to eq([
                                              {
                                                job_class: "DependencyParentJob",
                                                job_id: "parent-123"
                                              }
                                            ])
  end

  it "preserves standard ActiveJob set options" do
    job = child_job_class.set(depends_on: "parent-123", queue: "critical", priority: 10).perform_later

    expect(job.queue_name).to eq("critical")
    expect(job.priority).to eq(10)
  end

  it "rejects an empty dependency list" do
    expect { child_job_class.new.set(depends_on: []) }
      .to raise_error(ArgumentError, /must contain at least one/)
  end

  it "rejects unsupported dependency entries" do
    expect { child_job_class.new.set(depends_on: [Object.new]) }
      .to raise_error(ArgumentError, /ActiveJob instances, job IDs, or dependency hashes/)
  end

  it "rejects dependency hashes without identifiers" do
    expect { child_job_class.new.set(depends_on: [{ job_class: parent_job_class }]) }
      .to raise_error(ArgumentError, /must include job_id or workflow_id/)
  end

  it "rejects invalid failure policies" do
    expect { child_job_class.new.set(depends_on: "parent-123", on_dependency_failure: :retry) }
      .to raise_error(ArgumentError, /must be :fail or :ignore/)
  end

  it "rejects failure policy configuration without dependencies" do
    expect { child_job_class.new.set(on_dependency_failure: :ignore) }
      .to raise_error(ArgumentError, /requires depends_on/)
  end
end
