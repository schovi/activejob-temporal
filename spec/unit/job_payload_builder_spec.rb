# frozen_string_literal: true

require "spec_helper"
require "active_job"
require "activejob/temporal/signal_query_options"
require "base64"

describe ActiveJob::Temporal::JobPayloadBuilder do
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

    call_recorded_method(ActiveJob::Temporal::Logger, :info)
    call_recorded_method(ActiveJob::Temporal::Logger, :warn)
    call_recorded_method(ActiveJob::Temporal::Logger, :error)
  end

  it "builds a workflow payload with global activity defaults" do
    config.default_heartbeat_timeout = 45.seconds
    config.default_schedule_to_start_timeout = 2.minutes
    config.default_schedule_to_close_timeout = 20.minutes
    job = build_job("PayloadBuilderJob")

    payload = described_class.new(config).build(job)

    assert_equal(
      {
        start_to_close_timeout: 900.0,
        schedule_to_close_timeout: 1200.0,
        schedule_to_start_timeout: 120.0,
        heartbeat_timeout: 45.0
      },
      payload[:default_activity_options]
    )
  end

  it "includes the full ActiveJob serialized payload" do
    job_class = Class.new(ActiveJob::Base) do
      attr_accessor :tenant

      def self.name = "CustomSerializedPayloadJob"

      def serialize
        super.merge("tenant" => tenant)
      end
    end
    job = job_class.new("payload")
    job.tenant = "tenant-42"

    payload = described_class.new(config).build(job)

    assert_hash_includes(
      {
        "job_class" => "CustomSerializedPayloadJob",
        "job_id" => job.job_id,
        "queue_name" => "default",
        "tenant" => "tenant-42"
      },
      payload[:active_job]
    )
  end

  it "injects observability trace context into the workflow payload" do
    adapter_class = Class.new(ActiveJob::Temporal::Observability::Adapter) do
      def initialize
        super(:payload_trace_spec)
      end

      def trace_context_for_enqueue(_payload)
        { "traceparent" => "00-trace-span-01" }
      end
    end
    ActiveJob::Temporal::Observability.register_adapter(:payload_trace_spec, adapter_class)
    ActiveJob::Temporal.config.observability.use(:payload_trace_spec)
    job = build_job("TracePayloadBuilderJob")

    payload = described_class.new(ActiveJob::Temporal.config).build(
      job,
      encryption_context: { namespace: "default", workflow_id: "workflow-1" }
    )

    assert_equal(
      {
        "trace_context" => {
          "payload_trace_spec" => { "traceparent" => "00-trace-span-01" }
        }
      },
      payload[:observability]
    )
  ensure
    ActiveJob::Temporal::Observability.reset!
  end

  it "includes per-job temporal options" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "ScheduledTimeoutJob"

      temporal_options start_to_close_timeout: 2.hours
    end
    job = job_class.new

    payload = described_class.new(config).build(job)

    assert_equal({ start_to_close_timeout: 7200.0 }, payload[:temporal_options])
  end

  it "includes temporal options inherited from a parent job class" do
    parent_class = Class.new(ActiveJob::Base) do
      temporal_options start_to_close_timeout: 2.hours
    end
    job_class = Class.new(parent_class) do
      def self.name = "InheritedTimeoutJob"
    end
    job = job_class.new

    payload = described_class.new(config).build(job)

    assert_equal({ start_to_close_timeout: 7200.0 }, payload[:temporal_options])
  end

  it "includes the configured continue-as-new threshold" do
    config.continue_as_new_history_event_threshold = 10_000
    job = build_job("ContinueAsNewPayloadJob")

    payload = described_class.new(config).build(job)

    assert_equal({ history_event_threshold: 10_000 }, payload[:continue_as_new])
  end

  it "includes configured local activity helpers" do
    config.local_activity_helpers = [:rate_limit]
    job = build_job("LocalActivityPayloadJob")

    payload = described_class.new(config).build(job)

    assert_equal ["rate_limit"], payload[:local_activity_helpers]
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

    assert_equal(
      {
        job_class: "WorkflowInteractionJob",
        signals: %w[append_event progress],
        queries: %w[events progress],
        updates: %w[set_progress]
      },
      payload[:workflow_interactions]
    )
  end

  it "includes declared workflow identity metadata" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "WorkflowIdentityPayloadJob"

      temporal_workflow_name "payments.charge_payment"
      temporal_workflow_id_prefix "payment"
    end

    payload = described_class.new(config).build(job_class.new)

    assert_equal(
      {
        workflow_name: "payments.charge_payment",
        workflow_id_prefix: "payment"
      },
      payload[:workflow_identity]
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

    assert_equal 2, payload[:chain].size

    next_payload = payload_entry(payload[:chain], "PayloadBuilderNextJob")
    assert_hash_includes(
      {
        job_class: "PayloadBuilderNextJob",
        job_id: "#{job.job_id}:chain:1",
        queue_name: "mailers",
        arguments: [],
        activity_task_queue: "prod-mailers",
        temporal_options: { start_to_close_timeout: 7200.0 },
        rate_limits: [
          {
            limit: 5,
            interval: 60.0,
            key: "activejob-temporal:job:PayloadBuilderNextJob"
          }
        ]
      },
      next_payload
    )
    assert_hash_includes({ initial_interval: 10.0, maximum_attempts: 4 }, next_payload[:retry_policy])

    final_payload = payload_entry(payload[:chain], "PayloadBuilderFinalJob")
    assert_hash_includes(
      {
        job_class: "PayloadBuilderFinalJob",
        job_id: "#{job.job_id}:chain:2",
        queue_name: "reporting",
        arguments: [],
        activity_task_queue: "prod-priority_reports"
      },
      final_payload
    )
    assert_hash_includes({ maximum_attempts: 1 }, final_payload[:retry_policy])
  end

  it "includes external Temporal refs in chain payloads without ActiveJob execution metadata" do
    job = build_job("PayloadBuilderExternalChainRootJob")
    job.define_singleton_method(:temporal_chain) do
      [
        ActiveJob::Temporal.activity(
          "payments.AuthorizePayment",
          task_queue: "payments-kotlin",
          start_to_close_timeout: 30.seconds
        ),
        ActiveJob::Temporal.workflow(
          "inventory.ReserveInventoryWorkflow",
          task_queue: "inventory-kotlin",
          run_timeout: 5.minutes
        )
      ]
    end

    payload = described_class.new(config).build(job)

    assert_equal(
      [
        {
          temporal_operation: "activity",
          temporal_type: "payments.AuthorizePayment",
          options: {
            task_queue: "payments-kotlin",
            start_to_close_timeout: 30.0
          }
        },
        {
          temporal_operation: "workflow",
          temporal_type: "inventory.ReserveInventoryWorkflow",
          options: {
            task_queue: "inventory-kotlin",
            run_timeout: 300.0
          }
        }
      ],
      payload[:chain]
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
      temporal_workflow_name "invoices.send"
      temporal_workflow_id_prefix "invoice-child"
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

    assert_equal 2, payload[:child_workflows].size

    child_payload = payload_entry(payload[:child_workflows], "PayloadBuilderChildJob")
    assert_hash_includes(
      {
        job_class: "PayloadBuilderChildJob",
        job_id: "#{job.job_id}:child:1",
        workflow_id: "invoice-child:#{job.job_id}:child:1",
        queue_name: "mailers",
        arguments: [],
        activity_task_queue: "prod-mailers",
        workflow_task_queue: "prod-mailers",
        temporal_options: { start_to_close_timeout: 7200.0 },
        rate_limits: [
          {
            limit: 5,
            interval: 60.0,
            key: "activejob-temporal:job:PayloadBuilderChildJob"
          }
        ]
      },
      child_payload
    )
    assert_hash_includes({ initial_interval: 10.0, maximum_attempts: 4 }, child_payload[:retry_policy])
    assert_hash_includes(
      {
        job_class: "PayloadBuilderChildJob",
        job_id: "#{job.job_id}:child:1",
        queue_name: "mailers",
        tags: []
      },
      child_payload[:search_attributes]
    )
    assert_kind_of String, child_payload[:search_attributes][:enqueued_at]

    final_child_payload = payload_entry(payload[:child_workflows], "PayloadBuilderFinalChildJob")
    assert_hash_includes(
      {
        job_class: "PayloadBuilderFinalChildJob",
        job_id: "#{job.job_id}:child:2",
        workflow_id: "ajwf:PayloadBuilderFinalChildJob:#{job.job_id}:child:2",
        queue_name: "reporting",
        arguments: [],
        activity_task_queue: "prod-priority_reports",
        workflow_task_queue: "prod-priority_reports"
      },
      final_child_payload
    )
    assert_hash_includes({ maximum_attempts: 1 }, final_child_payload[:retry_policy])
    assert_hash_includes(
      {
        job_class: "PayloadBuilderFinalChildJob",
        job_id: "#{job.job_id}:child:2",
        queue_name: "reporting",
        tags: %w[fanout urgent]
      },
      final_child_payload[:search_attributes]
    )
  end

  it "includes external Temporal workflow refs in child workflow payloads" do
    job = build_job("PayloadBuilderExternalChildRootJob")
    job.define_singleton_method(:temporal_child_workflows) do
      [
        ActiveJob::Temporal.workflow(
          "fulfillment.PrepareShipmentWorkflow",
          task_queue: "fulfillment-kotlin",
          run_timeout: 5.minutes
        )
      ]
    end

    payload = described_class.new(config).build(job)

    assert_equal(
      [
        {
          temporal_operation: "workflow",
          temporal_type: "fulfillment.PrepareShipmentWorkflow",
          options: {
            task_queue: "fulfillment-kotlin",
            run_timeout: 300.0
          }
        }
      ],
      payload[:child_workflows]
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

    assert_equal(
      [
        {
          job_class: "DependencyBuilderParentJob",
          job_id: "parent-123",
          workflow_id: "ajwf:DependencyBuilderParentJob:parent-123"
        },
        {
          job_id: "search-only-parent"
        }
      ],
      payload[:dependencies]
    )
    assert_equal "ignore", payload[:dependency_failure_policy]
  end

  it "includes dependency wait options" do
    config.dependency_wait_timeout = 30.minutes
    config.dependency_wait_initial_interval = 5.seconds
    config.dependency_wait_max_interval = 1.minute
    config.dependency_wait_backoff = 3.0
    job = build_job("DependencyWaitBuilderJob")
    job.define_singleton_method(:temporal_dependencies) do
      [{ job_id: "parent-123" }]
    end
    job.define_singleton_method(:temporal_dependency_failure_policy) { :fail }

    payload = described_class.new(config).build(job)

    assert_equal(
      {
        timeout: 1800.0,
        initial_interval: 5.0,
        max_interval: 60.0,
        backoff: 3.0
      },
      payload[:dependency_wait]
    )
  end

  it "lets job dependency wait options override configuration defaults" do
    config.dependency_wait_timeout = 30.minutes
    job = build_job("DependencyWaitOverrideBuilderJob")
    job.define_singleton_method(:temporal_dependencies) do
      [{ job_id: "parent-123" }]
    end
    job.define_singleton_method(:temporal_dependency_wait) do
      { timeout: 60.0, initial_interval: 2.0 }
    end

    payload = described_class.new(config).build(job)

    assert_hash_includes(
      {
        timeout: 60.0,
        initial_interval: 2.0,
        max_interval: 60.0,
        backoff: 2.0
      },
      payload[:dependency_wait]
    )
  end

  it "includes per-job rate limits with a job-specific key" do
    config.rate_limiter = ->(_rate_limits) { 0 }
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "RateLimitedJob"

      rate_limit 100, per: :second
    end
    job = job_class.new

    payload = described_class.new(config).build(job)

    assert_equal(
      [
        {
          limit: 100,
          interval: 1.0,
          key: "activejob-temporal:job:RateLimitedJob"
        }
      ],
      payload[:rate_limits]
    )
  end

  it "requires a limiter backend when per-job rate limits are configured" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "MissingLimiterRateLimitedJob"

      rate_limit 100, per: :second
    end

    error = assert_raises(ActiveJob::Temporal::ConfigurationError) do
      described_class.new(config).build(job_class.new)
    end

    assert_match(/rate_limiter is required/, error.message)
  end

  it "includes global and per-job rate limits" do
    config.rate_limiter = ->(_rate_limits) { 0 }
    config.global_rate_limit = { limit: 1000, per: :minute }
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "GlobalAndJobRateLimitedJob"

      rate_limit 100, per: :second, key: "external-api"
    end

    payload = described_class.new(config).build(job_class.new)

    assert_equal(
      [
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
      ],
      payload[:rate_limits]
    )
  end

  it "adds dead letter metadata when a dead letter queue is configured" do
    config.dead_letter_queue = "failed_jobs"
    config.dead_letter_after_attempts = 3
    config.dead_letter_auto_discard_after = 7.days
    job = build_job("DeadLetterBuilderJob")

    payload = described_class.new(config).build(job)

    assert_equal(
      {
        queue: "failed_jobs",
        after_attempts: 3,
        auto_discard_after_seconds: 604_800.0,
        job_class: "DeadLetterBuilderJob",
        job_id: job.job_id,
        queue_name: "default"
      },
      payload[:dead_letter]
    )
  end

  it "omits dead letter metadata when dead letter routing is disabled" do
    job = build_job("NoDeadLetterBuilderJob")

    payload = described_class.new(config).build(job)

    refute payload.key?(:dead_letter)
  end

  it "uses dead_letter_after_attempts as the activity retry limit" do
    config.dead_letter_queue = "failed_jobs"
    config.dead_letter_after_attempts = 2
    call_recorded_method(
      ActiveJob::Temporal::RetryMapper,
      :for,
      returns: {
        initial_interval: 30.0,
        backoff_coefficient: 2.0,
        maximum_attempts: 5,
        non_retryable_error_types: []
      }
    )

    payload = described_class.new(config).build(build_job("DeadLetterAttemptsBuilderJob"))

    assert_equal 2, payload[:retry_policy][:maximum_attempts]
  end

  it "records the retry policy attempt limit when no dead letter threshold is configured" do
    config.dead_letter_queue = "failed_jobs"
    call_recorded_method(
      ActiveJob::Temporal::RetryMapper,
      :for,
      returns: {
        initial_interval: 30.0,
        backoff_coefficient: 2.0,
        maximum_attempts: 4,
        non_retryable_error_types: []
      }
    )

    payload = described_class.new(config).build(build_job("DeadLetterPolicyLimitBuilderJob"))

    assert_equal 4, payload[:dead_letter][:after_attempts]
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

    assert_hash_includes(
      {
        encrypted_payload: true,
        encrypted_payload_version: 1,
        dependency_failure_policy: "fail"
      },
      payload
    )
    assert_kind_of String, payload[:encrypted_data]
    assert_hash_includes({ start_to_close_timeout: 900.0 }, payload[:default_activity_options])
    assert_hash_includes({ maximum_attempts: 3 }, payload[:retry_policy])
    assert_hash_includes(
      { limit: 1000, interval: 60.0, key: "activejob-temporal:global" },
      payload[:rate_limits].first
    )
    assert_hash_includes(
      {
        queue: "failed_jobs",
        after_attempts: 3,
        job_class: "EncryptedBuilderJob",
        job_id: job.job_id
      },
      payload[:dead_letter]
    )
    assert_hash_includes(
      {
        job_class: "EncryptedBuilderJob",
        signals: ["pause"],
        queries: ["paused"]
      },
      payload[:workflow_interactions]
    )

    encrypted_child_payload = payload_entry(payload[:child_workflows], "EncryptedBuilderNextJob")
    assert_hash_includes(
      {
        job_class: "EncryptedBuilderNextJob",
        queue_name: "reporting",
        activity_task_queue: "reporting",
        workflow_task_queue: "reporting",
        workflow_id: "ajwf:EncryptedBuilderNextJob:#{job.job_id}:child:1"
      },
      encrypted_child_payload
    )

    encrypted_chain_payload = payload_entry(payload[:chain], "EncryptedBuilderNextJob")
    assert_hash_includes(
      {
        job_class: "EncryptedBuilderNextJob",
        queue_name: "reporting",
        activity_task_queue: "reporting"
      },
      encrypted_chain_payload
    )
    assert_hash_includes({ job_class: "EncryptedBuilderNextJob" }, encrypted_chain_payload[:dead_letter])
    assert_hash_includes(
      { job_id: "parent-123", workflow_id: "custom-parent-workflow" },
      payload[:dependencies].first
    )
    refute payload.key?(:job_class)

    decrypted_payload = ActiveJob::Temporal::Payload.deserialize_payload(payload, config: config)
    assert_hash_includes(
      {
        job_class: "EncryptedBuilderJob",
        dependency_failure_policy: "fail"
      },
      decrypted_payload
    )
    assert_hash_includes({ "start_to_close_timeout" => 900.0 }, decrypted_payload[:default_activity_options])
    assert_hash_includes({ "maximum_attempts" => 3 }, decrypted_payload[:retry_policy])
    assert_hash_includes(
      { "limit" => 1000, "interval" => 60.0, "key" => "activejob-temporal:global" },
      decrypted_payload[:rate_limits].first
    )
    assert_hash_includes({ "queue" => "failed_jobs" }, decrypted_payload[:dead_letter])
    assert_hash_includes(
      {
        "job_class" => "EncryptedBuilderNextJob",
        "queue_name" => "reporting",
        "activity_task_queue" => "reporting"
      },
      payload_entry(decrypted_payload[:chain], "EncryptedBuilderNextJob")
    )
    assert_hash_includes(
      {
        "job_class" => "EncryptedBuilderNextJob",
        "queue_name" => "reporting",
        "workflow_task_queue" => "reporting"
      },
      payload_entry(decrypted_payload[:child_workflows], "EncryptedBuilderNextJob")
    )
    assert_hash_includes(
      { "job_id" => "parent-123", "workflow_id" => "custom-parent-workflow" },
      decrypted_payload[:dependencies].first
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

    decrypted_tampered_payload = ActiveJob::Temporal::Payload.deserialize_payload(tampered_payload, config: config)

    assert_hash_includes({ "start_to_close_timeout" => 900.0 }, decrypted_tampered_payload[:default_activity_options])
    assert_hash_includes({ "maximum_attempts" => 3 }, decrypted_tampered_payload[:retry_policy])
    assert_hash_includes(
      {
        "job_class" => "EncryptedBuilderNextJob",
        "activity_task_queue" => "reporting"
      },
      payload_entry(decrypted_tampered_payload[:chain], "EncryptedBuilderNextJob")
    )
    assert_hash_includes(
      {
        "job_class" => "EncryptedBuilderNextJob",
        "workflow_task_queue" => "reporting"
      },
      payload_entry(decrypted_tampered_payload[:child_workflows], "EncryptedBuilderNextJob")
    )
    assert_hash_includes(
      { "job_id" => "parent-123", "workflow_id" => "custom-parent-workflow" },
      decrypted_tampered_payload[:dependencies].first
    )
    assert_equal "fail", decrypted_tampered_payload[:dependency_failure_policy]
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

    assert_hash_includes(
      {
        serialized_payload: true,
        payload_serializer: "message_pack",
        payload_serializer_version: 1,
        dependency_failure_policy: "ignore"
      },
      payload
    )
    assert_kind_of String, payload[:serialized_data]
    assert_hash_includes({ start_to_close_timeout: 900.0 }, payload[:default_activity_options])
    assert_hash_includes({ maximum_attempts: 3 }, payload[:retry_policy])
    assert_hash_includes(
      { limit: 1000, interval: 60.0, key: "activejob-temporal:global" },
      payload[:rate_limits].first
    )
    assert_hash_includes(
      {
        queue: "failed_jobs",
        after_attempts: 3,
        job_class: "SerializedBuilderJob",
        job_id: job.job_id
      },
      payload[:dead_letter]
    )
    assert_hash_includes(
      {
        job_class: "SerializedBuilderJob",
        signals: ["pause"],
        queries: ["paused"]
      },
      payload[:workflow_interactions]
    )

    serialized_child_payload = payload_entry(payload[:child_workflows], "SerializedBuilderNextJob")
    assert_hash_includes(
      {
        job_class: "SerializedBuilderNextJob",
        queue_name: "reporting",
        activity_task_queue: "reporting",
        workflow_task_queue: "reporting",
        workflow_id: "ajwf:SerializedBuilderNextJob:#{job.job_id}:child:1"
      },
      serialized_child_payload
    )

    serialized_chain_payload = payload_entry(payload[:chain], "SerializedBuilderNextJob")
    assert_hash_includes(
      {
        job_class: "SerializedBuilderNextJob",
        queue_name: "reporting",
        activity_task_queue: "reporting"
      },
      serialized_chain_payload
    )
    assert_hash_includes({ job_class: "SerializedBuilderNextJob" }, serialized_chain_payload[:dead_letter])
    assert_hash_includes(
      { job_id: "parent-123", workflow_id: "custom-parent-workflow" },
      payload[:dependencies].first
    )
    refute payload.key?(:job_class)
    refute payload.key?(:arguments)

    deserialized_payload = ActiveJob::Temporal::Payload.deserialize_payload(payload, config: config)
    assert_hash_includes(
      {
        job_class: "SerializedBuilderJob",
        dependency_failure_policy: "ignore"
      },
      deserialized_payload
    )
    assert_hash_includes({ start_to_close_timeout: 900.0 }, deserialized_payload[:default_activity_options])
    assert_hash_includes({ maximum_attempts: 3 }, deserialized_payload[:retry_policy])
    assert_hash_includes(
      { limit: 1000, interval: 60.0, key: "activejob-temporal:global" },
      deserialized_payload[:rate_limits].first
    )
    assert_hash_includes({ queue: "failed_jobs" }, deserialized_payload[:dead_letter])
    assert_hash_includes(
      {
        job_class: "SerializedBuilderNextJob",
        queue_name: "reporting",
        activity_task_queue: "reporting"
      },
      payload_entry(deserialized_payload[:chain], "SerializedBuilderNextJob")
    )
    assert_hash_includes(
      {
        job_class: "SerializedBuilderNextJob",
        queue_name: "reporting",
        workflow_task_queue: "reporting"
      },
      payload_entry(deserialized_payload[:child_workflows], "SerializedBuilderNextJob")
    )
    assert_hash_includes(
      { job_id: "parent-123", workflow_id: "custom-parent-workflow" },
      deserialized_payload[:dependencies].first
    )
  end

  it "enforces payload size after workflow-control fields are added" do
    job = build_job("FinalSizeBuilderJob")
    call_recorded_method(
      ActiveJob::Temporal::RetryMapper,
      :for,
      returns: { non_retryable_error_types: ["x" * 2048] }
    )

    config.max_payload_size_kb = 1

    error = assert_raises(ActiveJob::SerializationError) do
      described_class.new(config).build(job)
    end

    assert_match(/exceeds maximum allowed size/, error.message)
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

    assert_hash_includes(
      {
        external_payload: true,
        external_payload_version: 1,
        continue_as_new: { history_event_threshold: 10_000 }
      },
      payload
    )
    assert_kind_of String, payload[:external_payload_reference]
    assert_hash_includes({ start_to_close_timeout: 900.0 }, payload[:default_activity_options])
    assert_hash_includes({ maximum_attempts: 1 }, payload[:retry_policy])
    assert_hash_includes(
      {
        namespace: "default",
        workflow_id: "workflow-1",
        job_class: "ExternalBuilderJob",
        job_id: job.job_id,
        queue_name: "default"
      },
      adapter.metadata_for(payload.fetch(:external_payload_reference))
    )
    assert_hash_includes(
      {
        job_class: "ExternalBuilderJob",
        continue_as_new: { history_event_threshold: 10_000 }
      },
      ActiveJob::Temporal::Payload.deserialize_payload(payload, config: config)
    )
  end

  it "serializes once when enforcing final payload size" do
    job = build_job("SingleSizeBuilderJob")
    original_generate = JSON.method(:generate)
    recorder = call_recorded_method(JSON, :generate) do |*arguments, **keywords|
      original_generate.call(*arguments, **keywords)
    end

    described_class.new(config).build(job)

    assert_equal 1, recorder.calls_for(:generate).size
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

  def payload_entry(entries, job_class)
    entries.find { |entry| entry[:job_class] == job_class || entry["job_class"] == job_class } ||
      flunk("Expected payload entry for #{job_class}")
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
