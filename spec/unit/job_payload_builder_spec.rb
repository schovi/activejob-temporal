# frozen_string_literal: true

require "spec_helper"
require "active_job"
require "activejob/temporal/signal_query_options"
require "base64"

RSpec.describe ActiveJob::Temporal::JobPayloadBuilder do
  let(:config) { ActiveJob::Temporal::Configuration.new }

  before do
    ActiveJob::Temporal.configure do |global_config|
      global_config.max_payload_size_kb = 250
      global_config.encrypt_payload = false
      global_config.encryption_key = nil
      global_config.encryption_old_keys = []
      global_config.rate_limiter = nil
      global_config.global_rate_limit = nil
      global_config.payload_storage_adapter = nil
      global_config.payload_storage_threshold_kb = nil
    end

    allow(ActiveJob::Temporal::Logger).to receive(:info)
    allow(ActiveJob::Temporal::Logger).to receive(:warn)
    allow(ActiveJob::Temporal::Logger).to receive(:error)
  end

  it "builds a workflow payload with global activity defaults" do
    config.default_heartbeat_timeout = 45.seconds
    config.default_schedule_to_start_timeout = 2.minutes
    config.default_schedule_to_close_timeout = 20.minutes
    job = build_job("PayloadBuilderJob")

    payload = described_class.new(config).build(job)

    expect(payload[:default_activity_options]).to eq(
      start_to_close_timeout: 900.0,
      schedule_to_close_timeout: 1200.0,
      schedule_to_start_timeout: 120.0,
      heartbeat_timeout: 45.0
    )
  end

  it "includes per-job temporal options" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "ScheduledTimeoutJob"

      temporal_options start_to_close_timeout: 2.hours
    end
    job = job_class.new

    payload = described_class.new(config).build(job)

    expect(payload[:temporal_options]).to eq(start_to_close_timeout: 7200.0)
  end

  it "includes the configured continue-as-new threshold" do
    config.continue_as_new_history_event_threshold = 10_000
    job = build_job("ContinueAsNewPayloadJob")

    payload = described_class.new(config).build(job)

    expect(payload[:continue_as_new]).to eq(history_event_threshold: 10_000)
  end

  it "includes configured local activity helpers" do
    config.local_activity_helpers = [:rate_limit]
    job = build_job("LocalActivityPayloadJob")

    payload = described_class.new(config).build(job)

    expect(payload[:local_activity_helpers]).to eq(["rate_limit"])
  end

  it "includes workflow interaction metadata for declared signals, queries, and updates" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "WorkflowInteractionJob"

      temporal_signal :progress
      temporal_signal(:append_event) { |state, event| (state["events"] ||= []) << event }
      temporal_query(:progress) { |state| state["progress"] }
      temporal_query(:events) { |state| state["events"] || [] }
      temporal_update(:set_progress) { |state, value| state["progress"] = value }
    end
    job = job_class.new

    payload = described_class.new(config).build(job)

    expect(payload[:workflow_interactions]).to eq(
      job_class: "WorkflowInteractionJob",
      signals: %w[append_event progress],
      queries: %w[events progress],
      updates: %w[set_progress]
    )
  end

  it "includes chain activity payloads with each step's own execution metadata" do
    config.rate_limiter = ->(_rate_limits) { 0 }
    config.priority_task_queues = { 7 => "priority_reports" }
    config.task_queue_prefix = "prod-"
    next_job_class = Class.new(ActiveJob::Base) do
      def self.name = "PayloadBuilderNextJob"

      queue_as :mailers
      retry_on StandardError, wait: 10.seconds, attempts: 4
      temporal_options start_to_close_timeout: 2.hours
      rate_limit 5, per: :minute
    end
    stub_const("PayloadBuilderNextJob", next_job_class)
    final_job_class = Class.new(ActiveJob::Base) do
      def self.name = "PayloadBuilderFinalJob"
    end
    stub_const("PayloadBuilderFinalJob", final_job_class)
    job = build_job("PayloadBuilderChainRootJob")
    job.define_singleton_method(:temporal_chain) do
      [
        {
          job_class: next_job_class.name,
          options: {}
        },
        {
          job_class: final_job_class.name,
          options: {
            queue: "reporting",
            priority: 7
          }
        }
      ]
    end

    payload = described_class.new(config).build(job)

    expect(payload[:chain]).to contain_exactly(
      hash_including(
        job_class: "PayloadBuilderNextJob",
        job_id: "#{job.job_id}:chain:1",
        queue_name: "mailers",
        arguments: [],
        activity_task_queue: "prod-mailers",
        temporal_options: { start_to_close_timeout: 7200.0 },
        retry_policy: hash_including(initial_interval: 10.0, maximum_attempts: 4),
        rate_limits: [
          {
            limit: 5,
            interval: 60.0,
            key: "activejob-temporal:job:PayloadBuilderNextJob"
          }
        ]
      ),
      hash_including(
        job_class: "PayloadBuilderFinalJob",
        job_id: "#{job.job_id}:chain:2",
        queue_name: "reporting",
        arguments: [],
        activity_task_queue: "prod-priority_reports",
        retry_policy: hash_including(maximum_attempts: 1)
      )
    )
  end

  it "includes child workflow payloads with child workflow IDs and execution metadata" do
    config.rate_limiter = ->(_rate_limits) { 0 }
    config.priority_task_queues = { 7 => "priority_reports" }
    config.task_queue_prefix = "prod-"
    config.enable_search_attributes = true
    child_job_class = Class.new(ActiveJob::Base) do
      def self.name = "PayloadBuilderChildJob"

      queue_as :mailers
      retry_on StandardError, wait: 10.seconds, attempts: 4
      temporal_options start_to_close_timeout: 2.hours
      rate_limit 5, per: :minute
    end
    stub_const("PayloadBuilderChildJob", child_job_class)
    final_child_job_class = Class.new(ActiveJob::Base) do
      def self.name = "PayloadBuilderFinalChildJob"
    end
    stub_const("PayloadBuilderFinalChildJob", final_child_job_class)
    job = build_job("PayloadBuilderChildRootJob")
    job.define_singleton_method(:temporal_child_workflows) do
      [
        {
          job_class: child_job_class.name,
          options: {}
        },
        {
          job_class: final_child_job_class.name,
          options: {
            queue: "reporting",
            priority: 7,
            tags: %w[fanout urgent]
          }
        }
      ]
    end

    payload = described_class.new(config).build(job)

    expect(payload[:child_workflows]).to contain_exactly(
      hash_including(
        job_class: "PayloadBuilderChildJob",
        job_id: "#{job.job_id}:child:1",
        workflow_id: "ajwf:PayloadBuilderChildJob:#{job.job_id}:child:1",
        queue_name: "mailers",
        arguments: [],
        activity_task_queue: "prod-mailers",
        workflow_task_queue: "prod-mailers",
        temporal_options: { start_to_close_timeout: 7200.0 },
        retry_policy: hash_including(initial_interval: 10.0, maximum_attempts: 4),
        rate_limits: [
          {
            limit: 5,
            interval: 60.0,
            key: "activejob-temporal:job:PayloadBuilderChildJob"
          }
        ],
        search_attributes: hash_including(
          job_class: "PayloadBuilderChildJob",
          job_id: "#{job.job_id}:child:1",
          queue_name: "mailers",
          enqueued_at: a_kind_of(String),
          tags: []
        )
      ),
      hash_including(
        job_class: "PayloadBuilderFinalChildJob",
        job_id: "#{job.job_id}:child:2",
        workflow_id: "ajwf:PayloadBuilderFinalChildJob:#{job.job_id}:child:2",
        queue_name: "reporting",
        arguments: [],
        activity_task_queue: "prod-priority_reports",
        workflow_task_queue: "prod-priority_reports",
        retry_policy: hash_including(maximum_attempts: 1),
        search_attributes: hash_including(
          job_class: "PayloadBuilderFinalChildJob",
          job_id: "#{job.job_id}:child:2",
          queue_name: "reporting",
          tags: %w[fanout urgent]
        )
      )
    )
  end

  it "includes dependency metadata with default workflow references" do
    job = build_job("DependencyBuilderJob")
    job.define_singleton_method(:temporal_dependencies) do
      [
        {
          job_class: "DependencyBuilderParentJob",
          job_id: "parent-123"
        },
        {
          job_id: "search-only-parent"
        }
      ]
    end
    job.define_singleton_method(:temporal_dependency_failure_policy) { :ignore }

    payload = described_class.new(config).build(job)

    expect(payload[:dependencies]).to eq([
                                           {
                                             job_class: "DependencyBuilderParentJob",
                                             job_id: "parent-123",
                                             workflow_id: "ajwf:DependencyBuilderParentJob:parent-123"
                                           },
                                           {
                                             job_id: "search-only-parent"
                                           }
                                         ])
    expect(payload[:dependency_failure_policy]).to eq("ignore")
  end

  it "includes per-job rate limits with a job-specific key" do
    config.rate_limiter = ->(_rate_limits) { 0 }
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "RateLimitedJob"

      rate_limit 100, per: :second
    end
    job = job_class.new

    payload = described_class.new(config).build(job)

    expect(payload[:rate_limits]).to eq([
                                          {
                                            limit: 100,
                                            interval: 1.0,
                                            key: "activejob-temporal:job:RateLimitedJob"
                                          }
                                        ])
  end

  it "requires a limiter backend when per-job rate limits are configured" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "MissingLimiterRateLimitedJob"

      rate_limit 100, per: :second
    end

    expect { described_class.new(config).build(job_class.new) }
      .to raise_error(ActiveJob::Temporal::ConfigurationError, /rate_limiter is required/)
  end

  it "includes global and per-job rate limits" do
    config.rate_limiter = ->(_rate_limits) { 0 }
    config.global_rate_limit = { limit: 1000, per: :minute }
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "GlobalAndJobRateLimitedJob"

      rate_limit 100, per: :second, key: "external-api"
    end

    payload = described_class.new(config).build(job_class.new)

    expect(payload[:rate_limits]).to eq([
                                          {
                                            limit: 1000,
                                            interval: 60.0,
                                            key: "activejob-temporal:global"
                                          },
                                          {
                                            limit: 100,
                                            interval: 1.0,
                                            key: "external-api"
                                          }
                                        ])
  end

  it "adds dead letter metadata when a dead letter queue is configured" do
    config.dead_letter_queue = "failed_jobs"
    config.dead_letter_after_attempts = 3
    config.dead_letter_auto_discard_after = 7.days
    job = build_job("DeadLetterBuilderJob")

    payload = described_class.new(config).build(job)

    expect(payload[:dead_letter]).to eq(
      queue: "failed_jobs",
      after_attempts: 3,
      auto_discard_after_seconds: 604_800.0,
      job_class: "DeadLetterBuilderJob",
      job_id: job.job_id,
      queue_name: "default"
    )
  end

  it "omits dead letter metadata when dead letter routing is disabled" do
    job = build_job("NoDeadLetterBuilderJob")

    payload = described_class.new(config).build(job)

    expect(payload).not_to have_key(:dead_letter)
  end

  it "uses dead_letter_after_attempts as the activity retry limit" do
    config.dead_letter_queue = "failed_jobs"
    config.dead_letter_after_attempts = 2
    allow(ActiveJob::Temporal::RetryMapper).to receive(:for).and_return(
      initial_interval: 30.0,
      backoff_coefficient: 2.0,
      maximum_attempts: 5,
      non_retryable_error_types: []
    )

    payload = described_class.new(config).build(build_job("DeadLetterAttemptsBuilderJob"))

    expect(payload[:retry_policy][:maximum_attempts]).to eq(2)
  end

  it "records the retry policy attempt limit when no dead letter threshold is configured" do
    config.dead_letter_queue = "failed_jobs"
    allow(ActiveJob::Temporal::RetryMapper).to receive(:for).and_return(
      initial_interval: 30.0,
      backoff_coefficient: 2.0,
      maximum_attempts: 4,
      non_retryable_error_types: []
    )

    payload = described_class.new(config).build(build_job("DeadLetterPolicyLimitBuilderJob"))

    expect(payload[:dead_letter][:after_attempts]).to eq(4)
  end

  it "keeps workflow-control fields readable when payload encryption is enabled" do
    job = build_job("EncryptedBuilderJob", workflow_interactions: true)
    stub_const("EncryptedBuilderNextJob", Class.new(ActiveJob::Base) do
      def self.name = "EncryptedBuilderNextJob"
    end)
    job.define_singleton_method(:temporal_chain) do
      [
        {
          job_class: "EncryptedBuilderNextJob",
          options: {
            queue: "reporting"
          }
        }
      ]
    end
    job.define_singleton_method(:temporal_child_workflows) do
      [
        {
          job_class: "EncryptedBuilderNextJob",
          options: {
            queue: "reporting"
          }
        }
      ]
    end
    job.define_singleton_method(:temporal_dependencies) do
      [{ job_id: "parent-123", workflow_id: "custom-parent-workflow" }]
    end
    job.define_singleton_method(:temporal_dependency_failure_policy) { :fail }

    config.encryption_key = encryption_key
    config.encryption_old_keys = []
    config.encrypt_payload = true
    config.dead_letter_queue = "failed_jobs"
    config.dead_letter_after_attempts = 3
    config.rate_limiter = ->(_rate_limits) { 0 }
    config.global_rate_limit = { limit: 1000, per: :minute }

    payload = described_class.new(config).build(job)

    expect(payload).to include(
      encrypted_payload: true,
      encrypted_payload_version: 1,
      encrypted_data: a_kind_of(String),
      default_activity_options: hash_including(start_to_close_timeout: 900.0),
      retry_policy: hash_including(maximum_attempts: 3),
      rate_limits: [hash_including(limit: 1000, interval: 60.0, key: "activejob-temporal:global")],
      dead_letter: hash_including(
        queue: "failed_jobs",
        after_attempts: 3,
        job_class: "EncryptedBuilderJob",
        job_id: job.job_id
      ),
      workflow_interactions: hash_including(
        job_class: "EncryptedBuilderJob",
        signals: ["pause"],
        queries: ["paused"]
      ),
      child_workflows: [
        hash_including(
          job_class: "EncryptedBuilderNextJob",
          queue_name: "reporting",
          activity_task_queue: "reporting",
          workflow_task_queue: "reporting",
          workflow_id: "ajwf:EncryptedBuilderNextJob:#{job.job_id}:child:1"
        )
      ],
      chain: [
        hash_including(
          job_class: "EncryptedBuilderNextJob",
          queue_name: "reporting",
          activity_task_queue: "reporting",
          dead_letter: hash_including(job_class: "EncryptedBuilderNextJob")
        )
      ],
      dependencies: [
        hash_including(job_id: "parent-123", workflow_id: "custom-parent-workflow")
      ],
      dependency_failure_policy: "fail"
    )
    expect(payload).not_to have_key(:job_class)
    expect(ActiveJob::Temporal::Payload.deserialize_payload(payload, config: config)).to include(
      job_class: "EncryptedBuilderJob",
      default_activity_options: hash_including("start_to_close_timeout" => 900.0),
      retry_policy: hash_including("maximum_attempts" => 3),
      rate_limits: [hash_including("limit" => 1000, "interval" => 60.0, "key" => "activejob-temporal:global")],
      dead_letter: hash_including("queue" => "failed_jobs"),
      chain: [
        hash_including(
          "job_class" => "EncryptedBuilderNextJob",
          "queue_name" => "reporting",
          "activity_task_queue" => "reporting"
        )
      ],
      child_workflows: [
        hash_including(
          "job_class" => "EncryptedBuilderNextJob",
          "queue_name" => "reporting",
          "workflow_task_queue" => "reporting"
        )
      ],
      dependencies: [
        hash_including("job_id" => "parent-123", "workflow_id" => "custom-parent-workflow")
      ],
      dependency_failure_policy: "fail"
    )

    tampered_payload = payload.merge(
      default_activity_options: { start_to_close_timeout: 1.0 },
      retry_policy: { maximum_attempts: 1 },
      chain: [
        {
          job_class: "TamperedChainJob",
          activity_task_queue: "tampered"
        }
      ],
      child_workflows: [
        {
          job_class: "TamperedChildJob",
          workflow_task_queue: "tampered"
        }
      ],
      dependencies: [
        { job_id: "tampered-parent", workflow_id: "tampered-workflow" }
      ],
      dependency_failure_policy: "ignore"
    )

    expect(ActiveJob::Temporal::Payload.deserialize_payload(tampered_payload, config: config)).to include(
      default_activity_options: hash_including("start_to_close_timeout" => 900.0),
      retry_policy: hash_including("maximum_attempts" => 3),
      chain: [
        hash_including(
          "job_class" => "EncryptedBuilderNextJob",
          "activity_task_queue" => "reporting"
        )
      ],
      child_workflows: [
        hash_including(
          "job_class" => "EncryptedBuilderNextJob",
          "workflow_task_queue" => "reporting"
        )
      ],
      dependencies: [
        hash_including("job_id" => "parent-123", "workflow_id" => "custom-parent-workflow")
      ],
      dependency_failure_policy: "fail"
    )
  end

  it "keeps workflow-control fields outside non-JSON serializer envelopes" do
    config.payload_serializer = :message_pack
    config.dead_letter_queue = "failed_jobs"
    config.dead_letter_after_attempts = 3
    config.rate_limiter = ->(_rate_limits) { 0 }
    config.global_rate_limit = { limit: 1000, per: :minute }
    job = build_job("SerializedBuilderJob", workflow_interactions: true)
    stub_const("SerializedBuilderNextJob", Class.new(ActiveJob::Base) do
      def self.name = "SerializedBuilderNextJob"
    end)
    job.define_singleton_method(:temporal_chain) do
      [
        {
          job_class: "SerializedBuilderNextJob",
          options: {
            queue: "reporting"
          }
        }
      ]
    end
    job.define_singleton_method(:temporal_child_workflows) do
      [
        {
          job_class: "SerializedBuilderNextJob",
          options: {
            queue: "reporting"
          }
        }
      ]
    end
    job.define_singleton_method(:temporal_dependencies) do
      [{ job_id: "parent-123", workflow_id: "custom-parent-workflow" }]
    end
    job.define_singleton_method(:temporal_dependency_failure_policy) { :ignore }

    payload = described_class.new(config).build(job)

    expect(payload).to include(
      serialized_payload: true,
      payload_serializer: "message_pack",
      payload_serializer_version: 1,
      serialized_data: a_kind_of(String),
      default_activity_options: hash_including(start_to_close_timeout: 900.0),
      retry_policy: hash_including(maximum_attempts: 3),
      rate_limits: [hash_including(limit: 1000, interval: 60.0, key: "activejob-temporal:global")],
      dead_letter: hash_including(
        queue: "failed_jobs",
        after_attempts: 3,
        job_class: "SerializedBuilderJob",
        job_id: job.job_id
      ),
      workflow_interactions: hash_including(
        job_class: "SerializedBuilderJob",
        signals: ["pause"],
        queries: ["paused"]
      ),
      child_workflows: [
        hash_including(
          job_class: "SerializedBuilderNextJob",
          queue_name: "reporting",
          activity_task_queue: "reporting",
          workflow_task_queue: "reporting",
          workflow_id: "ajwf:SerializedBuilderNextJob:#{job.job_id}:child:1"
        )
      ],
      chain: [
        hash_including(
          job_class: "SerializedBuilderNextJob",
          queue_name: "reporting",
          activity_task_queue: "reporting",
          dead_letter: hash_including(job_class: "SerializedBuilderNextJob")
        )
      ],
      dependencies: [
        hash_including(job_id: "parent-123", workflow_id: "custom-parent-workflow")
      ],
      dependency_failure_policy: "ignore"
    )
    expect(payload).not_to have_key(:job_class)
    expect(payload).not_to have_key(:arguments)

    expect(ActiveJob::Temporal::Payload.deserialize_payload(payload, config: config)).to include(
      job_class: "SerializedBuilderJob",
      default_activity_options: hash_including(start_to_close_timeout: 900.0),
      retry_policy: hash_including(maximum_attempts: 3),
      rate_limits: [hash_including(limit: 1000, interval: 60.0, key: "activejob-temporal:global")],
      dead_letter: hash_including(queue: "failed_jobs"),
      chain: [
        hash_including(
          job_class: "SerializedBuilderNextJob",
          queue_name: "reporting",
          activity_task_queue: "reporting"
        )
      ],
      child_workflows: [
        hash_including(
          job_class: "SerializedBuilderNextJob",
          queue_name: "reporting",
          workflow_task_queue: "reporting"
        )
      ],
      dependencies: [
        hash_including(job_id: "parent-123", workflow_id: "custom-parent-workflow")
      ],
      dependency_failure_policy: "ignore"
    )
  end

  it "enforces payload size after workflow-control fields are added" do
    job = build_job("FinalSizeBuilderJob")
    allow(ActiveJob::Temporal::RetryMapper).to receive(:for).and_return(
      non_retryable_error_types: ["x" * 2048]
    )

    config.max_payload_size_kb = 1

    expect { described_class.new(config).build(job) }
      .to raise_error(ActiveJob::SerializationError, /exceeds maximum allowed size/)
  end

  it "offloads payloads after workflow-control fields are added" do
    adapter = memory_payload_storage_adapter
    config.payload_storage_adapter = adapter
    config.payload_storage_threshold_kb = 1
    config.max_payload_size_kb = 1
    config.continue_as_new_history_event_threshold = 10_000
    job = build_job("ExternalBuilderJob")
    job.arguments = ["x" * 2048]

    payload = described_class.new(config).build(
      job,
      encryption_context: { namespace: "default", workflow_id: "workflow-1" }
    )

    expect(payload).to include(
      external_payload: true,
      external_payload_version: 1,
      external_payload_reference: a_kind_of(String),
      default_activity_options: hash_including(start_to_close_timeout: 900.0),
      retry_policy: hash_including(maximum_attempts: 1),
      continue_as_new: { history_event_threshold: 10_000 }
    )
    expect(adapter.metadata_for(payload.fetch(:external_payload_reference))).to include(
      namespace: "default",
      workflow_id: "workflow-1",
      job_class: "ExternalBuilderJob",
      job_id: job.job_id,
      queue_name: "default"
    )
    expect(ActiveJob::Temporal::Payload.deserialize_payload(payload, config: config)).to include(
      job_class: "ExternalBuilderJob",
      continue_as_new: { history_event_threshold: 10_000 }
    )
  end

  it "serializes once when enforcing final payload size" do
    job = build_job("SingleSizeBuilderJob")
    allow(JSON).to receive(:generate).and_call_original

    described_class.new(config).build(job)

    expect(JSON).to have_received(:generate).once
  end

  private

  def build_job(name, workflow_interactions: false)
    Class.new(ActiveJob::Base) do
      define_singleton_method(:name) { name }
      if workflow_interactions
        define_singleton_method(:temporal_signal_handler_names) { ["pause"] }
        define_singleton_method(:temporal_query_handler_names) { ["paused"] }
      end
    end.new
  end

  def encryption_key
    Base64.strict_encode64("builder-key".ljust(32, "-")[0, 32])
  end

  def memory_payload_storage_adapter
    Class.new do
      def initialize
        @payloads = {}
        @metadata = {}
      end

      def dump(payload, metadata:)
        reference = "payload-#{@payloads.length + 1}"
        @payloads[reference] = payload
        @metadata[reference] = metadata
        reference
      end

      def load(reference)
        @payloads.fetch(reference)
      end

      def metadata_for(reference)
        @metadata.fetch(reference)
      end
    end.new
  end
end
