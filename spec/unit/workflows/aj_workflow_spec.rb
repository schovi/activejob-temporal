# frozen_string_literal: true

require "spec_helper"
require "time"
require "activejob/temporal/workflows/aj_workflow"

module AjWorkflowSpecSupport
  WorkflowInfo = Struct.new(:workflow_id, :first_execution_run_id, :run_id, keyword_init: true)
  ChildWorkflowHandle = Struct.new(:result, keyword_init: true)

  class RecordingLogger
    attr_reader :warn_calls

    def initialize
      @warn_calls = []
    end

    def warn(attributes)
      warn_calls << attributes
    end
  end
end

describe ActiveJob::Temporal::Workflows::AjWorkflow do
  let(:workflow) { described_class.new }

  let(:activity_timeout) { 900.0 }
  let(:retry_policy_hash) do
    {
      initial_interval: 30.0,
      backoff_coefficient: 2.0,
      maximum_attempts: 3,
      non_retryable_error_types: []
    }
  end
  let(:base_payload) do
    {
      "job_class" => "SampleJob",
      "job_id" => "abc-123",
      "queue_name" => "default",
      "arguments" => [],
      "default_activity_options" => {
        "start_to_close_timeout" => activity_timeout
      },
      "retry_policy" => retry_policy_hash
    }
  end

  before do
    stub_const("SampleJob", Class.new)
    @workflow_now = Time.utc(2024, 1, 1, 12, 0, 0)
    @workflow_history_length = 1
    @workflow_history_lengths = nil
    @continue_as_new_suggested = false
    @search_attributes = nil
    @all_handlers_finished = true
    @workflow_patches = Hash.new(true)
    @execute_activity_handler = proc { :activity_result }
    @execute_child_workflow_handler = proc { :child_workflow_result }
    @execute_local_activity_handler = proc { :activity_result }
    @start_child_workflow_handler = proc {}
    @timeout_handler = proc { |_duration, *_args, **_options, &block| block.call }
    @wait_condition_handler = proc { |&condition| condition&.call }
    @create_nexus_client_handler = proc {}
    @workflow_info = AjWorkflowSpecSupport::WorkflowInfo.new(
      workflow_id: "ajwf:SampleJob:abc-123",
      first_execution_run_id: "run-123",
      run_id: "run-123"
    )
    @workflow_logger = AjWorkflowSpecSupport::RecordingLogger.new

    call_recorded_method(Temporalio::Workflow, :now) { @workflow_now }
    @history_length_recorder = call_recorded_method(Temporalio::Workflow, :current_history_length) do
      next @workflow_history_length unless @workflow_history_lengths

      @workflow_history_lengths.length > 1 ? @workflow_history_lengths.shift : @workflow_history_lengths.first
    end
    call_recorded_method(Temporalio::Workflow, :continue_as_new_suggested) { @continue_as_new_suggested }
    call_recorded_method(Temporalio::Workflow, :search_attributes) { @search_attributes }
    @all_handlers_finished_recorder = call_recorded_method(Temporalio::Workflow, :all_handlers_finished?) do
      @all_handlers_finished
    end
    @patched_recorder = call_recorded_method(Temporalio::Workflow, :patched) do |patch_name|
      @workflow_patches[patch_name]
    end
    @execute_activity_recorder = call_recorded_method(Temporalio::Workflow, :execute_activity) do |*args, **options|
      @execute_activity_handler.call(*args, **options)
    end
    @execute_child_workflow_recorder =
      call_recorded_method(Temporalio::Workflow, :execute_child_workflow) do |*args, **options|
        @execute_child_workflow_handler.call(*args, **options)
      end
    @execute_local_activity_recorder =
      call_recorded_method(Temporalio::Workflow, :execute_local_activity) do |*args, **options|
        @execute_local_activity_handler.call(*args, **options)
      end
    @sleep_recorder = call_recorded_method(Temporalio::Workflow, :sleep)
    @start_child_workflow_recorder =
      call_recorded_method(Temporalio::Workflow, :start_child_workflow) do |*args, **options|
        @start_child_workflow_handler.call(*args, **options)
      end
    @timeout_recorder = call_recorded_method(Temporalio::Workflow, :timeout) do |*args, **options, &block|
      @timeout_handler.call(*args, **options, &block)
    end
    @wait_condition_recorder = call_recorded_method(Temporalio::Workflow, :wait_condition) do |&condition|
      @wait_condition_handler.call(&condition)
    end
    call_recorded_method(Temporalio::Workflow, :info) { @workflow_info }
    call_recorded_method(Temporalio::Workflow, :logger) { @workflow_logger }
    @create_nexus_client_recorder = call_recorded_method(Temporalio::Workflow, :create_nexus_client) do |**options|
      @create_nexus_client_handler.call(**options)
    end
    call_recorded_method(ActiveJob::Temporal::RetryMapper, :for, returns: {})
  end

  def workflow_class
    described_class
  end

  def workflow_history_lengths(*lengths)
    @workflow_history_lengths = lengths
  end

  def activity_calls
    @execute_activity_recorder.calls_for(:execute_activity)
  end

  def last_activity_call
    activity_calls.last
  end

  def child_workflow_calls
    @execute_child_workflow_recorder.calls_for(:execute_child_workflow)
  end

  def local_activity_calls
    @execute_local_activity_recorder.calls_for(:execute_local_activity)
  end

  def sleep_calls
    @sleep_recorder.calls_for(:sleep)
  end

  def sleep_durations
    sleep_calls.map { |call| call.arguments.first }
  end

  def start_child_workflow_calls
    @start_child_workflow_recorder.calls_for(:start_child_workflow)
  end

  def timeout_calls
    @timeout_recorder.calls_for(:timeout)
  end

  def assert_activity_executed(expected_payload = nil)
    call = last_activity_call

    assert_equal ActiveJob::Temporal::Activities::AjRunnerActivity, call.arguments[0]
    assert_equal expected_payload, call.arguments[1] if expected_payload
    assert_kind_of Temporalio::RetryPolicy, call.keywords[:retry_policy]
    call
  end

  def assert_hash_matches(expected, actual)
    expected.each do |key, value|
      if value.is_a?(Hash)
        assert_hash_matches value, actual.fetch(key)
      else
        assert_equal value, actual.fetch(key)
      end
    end
  end

  describe "Nexus integration seam" do
    it "creates Nexus clients from the workflow layer" do
      nexus_client = Object.new

      @create_nexus_client_handler = proc { nexus_client }

      assert_same nexus_client, workflow.send(:nexus_client_for, endpoint: "payments", service: "authorization")
      assert_called_with(
        @create_nexus_client_recorder,
        :create_nexus_client,
        endpoint: "payments",
        service: "authorization"
      )
    end
  end

  describe "#execute" do
    describe "when payload has no scheduled_at" do
      it "invokes the activity immediately" do
        workflow.execute(base_payload)

        assert_empty sleep_calls
        activity_call = assert_activity_executed(base_payload)
        assert_equal activity_timeout, activity_call.keywords[:start_to_close_timeout]
      end

      it "uses the scheduled workflow occurrence ID as the activity job identity" do
        @workflow_info = AjWorkflowSpecSupport::WorkflowInfo.new(
          workflow_id: "ajschwf:reports-2024-01-01T12:00:00Z",
          first_execution_run_id: "run-123"
        )
        payload = base_payload.merge(
          "job_id" => "ajsch:reports",
          "schedule_id" => "ajsch:reports",
          "schedule_workflow_id_prefix" => "ajschwf:reports"
        )

        workflow.execute(payload)

        assert_hash_includes(
          {
            "job_id" => "ajschwf:reports-2024-01-01T12:00:00Z:run-123",
            "schedule_execution_job_id" => "ajschwf:reports-2024-01-01T12:00:00Z:run-123",
            "schedule_id" => "ajsch:reports"
          },
          last_activity_call.arguments[1]
        )
        assert_hash_includes(
          {
            "job_id" => "ajschwf:reports-2024-01-01T12:00:00Z:run-123"
          },
          workflow.handle_dynamic_query("state")
        )
      end
    end

    describe "when payload is scheduled in the future" do
      it "sleeps for the exact delay before executing" do
        current_time = Time.utc(2024, 1, 1, 12, 0, 0)
        scheduled_time = current_time + 300
        payload = base_payload.merge("scheduled_at" => scheduled_time.iso8601)

        @workflow_now = current_time

        workflow.execute(payload)

        assert_in_delta 300.0, sleep_calls.first.arguments.first, 1e-6
        activity_call = assert_activity_executed(payload)
        assert_equal activity_timeout, activity_call.keywords[:start_to_close_timeout]
      end
    end

    describe "when scheduled_at is in the past" do
      it "skips sleeping and runs immediately" do
        current_time = Time.utc(2024, 1, 1, 12, 0, 0)
        payload = base_payload.merge("scheduled_at" => (current_time - 120).iso8601)

        @workflow_now = current_time

        workflow.execute(payload)

        assert_empty sleep_calls
        refute_empty activity_calls
      end
    end

    describe "when retry policy metadata is available" do
      it "passes the retry policy through to the activity call" do
        custom_retry_policy = {
          initial_interval: 15.0,
          backoff_coefficient: 1.5,
          maximum_attempts: 5,
          non_retryable_error_types: []
        }
        payload = base_payload.merge("retry_policy" => custom_retry_policy)

        workflow.execute(payload)

        activity_call = assert_activity_executed(payload)
        assert_equal activity_timeout, activity_call.keywords[:start_to_close_timeout]
      end

      it "uses Temporal retry defaults when optional retry fields are nil" do
        custom_retry_policy = {
          "initial_interval" => nil,
          "backoff_coefficient" => nil,
          "max_interval" => nil,
          "maximum_attempts" => 3,
          "non_retryable_error_types" => nil
        }
        payload = base_payload.merge("retry_policy" => custom_retry_policy)

        workflow.execute(payload)

        retry_policy = last_activity_call.keywords[:retry_policy]

        assert_equal 1.0, retry_policy.initial_interval
        assert_equal 2.0, retry_policy.backoff_coefficient
        assert_nil retry_policy.max_interval
        assert_equal 3, retry_policy.max_attempts
        assert_nil retry_policy.non_retryable_error_types
      end
    end

    describe "when payload is encrypted" do
      it "passes the encrypted envelope to the activity without reading encryption config" do
        call_recorded_method(
          ActiveJob::Temporal,
          :config,
          raises: RuntimeError.new("workflow must not decrypt payload")
        )
        encrypted_payload = {
          "encrypted_payload" => true,
          "encrypted_payload_version" => 1,
          "encrypted_data" => "opaque-ciphertext",
          "default_activity_options" => {
            "start_to_close_timeout" => activity_timeout
          },
          "retry_policy" => retry_policy_hash
        }

        workflow.execute(encrypted_payload)

        activity_call = assert_activity_executed(encrypted_payload)
        assert_equal activity_timeout, activity_call.keywords[:start_to_close_timeout]
      end
    end

    describe "when continue-as-new is configured" do
      it "does not roll over while workflow history stays below the threshold" do
        payload = base_payload.merge("continue_as_new" => { "history_event_threshold" => 10 })

        workflow.execute(payload)

        refute_empty activity_calls
      end

      it "keeps rollover behind a deterministic workflow patch marker" do
        payload = base_payload.merge("continue_as_new" => { "history_event_threshold" => 5 })

        @workflow_history_length = 5
        @workflow_patches["activejob-temporal.continue-as-new-v1"] = false

        workflow.execute(payload)

        refute_empty activity_calls
      end

      it "rolls over with job payload, restored state, and current search attributes when threshold is reached" do
        search_attributes = Object.new
        continue_error = StandardError.new("continue as new")
        payload = base_payload.merge("continue_as_new" => { "history_event_threshold" => 5 })

        @workflow_history_length = 5
        @search_attributes = search_attributes
        continue_as_new_recorder =
          call_recorded_method(Temporalio::Workflow::ContinueAsNewError, :new, returns: continue_error)

        workflow.handle_dynamic_signal("pause", "manual hold")

        error = assert_raises(StandardError) { workflow.execute(payload) }

        assert_same continue_error, error
        refute_empty @all_handlers_finished_recorder.calls_for(:all_handlers_finished?)
        continue_as_new_call = continue_as_new_recorder.calls_for(:new).last
        rollover_payload = continue_as_new_call.arguments.first
        assert_hash_includes(
          {
            "job_class" => "SampleJob",
            "job_id" => "abc-123",
            "queue_name" => "default",
            "continue_as_new" => { "history_event_threshold" => 5 }
          },
          rollover_payload
        )
        assert_hash_includes(
          {
            "job_class" => "SampleJob",
            "job_id" => "abc-123",
            "paused" => true,
            "pause_reason" => "manual hold",
            "phase" => "continuing_as_new"
          },
          rollover_payload.fetch("workflow_state")
        )
        assert_equal({ search_attributes: search_attributes }, continue_as_new_call.keywords)
        assert_empty activity_calls
      end

      it "restores deterministic workflow state supplied by the previous run" do
        payload = base_payload.merge(
          "workflow_state" => {
            "phase" => "waiting_dependencies",
            "paused" => false,
            "signals" => {
              "progress" => {
                "args" => [75],
                "received_at" => "2024-01-01T12:00:00Z"
              }
            },
            "updates" => {},
            "custom" => { "progress" => 75 }
          }
        )

        workflow.execute(payload)

        state = workflow.handle_dynamic_query("state")

        assert_hash_includes(
          {
            "job_class" => "SampleJob",
            "job_id" => "abc-123",
            "custom" => { "progress" => 75 }
          },
          state
        )
        assert_includes state.fetch("signals"), "progress"
      end

      it "keeps restored workflow state behind a deterministic workflow patch marker" do
        payload = base_payload.merge(
          "workflow_state" => {
            "phase" => "waiting_dependencies",
            "paused" => false,
            "signals" => {},
            "updates" => {},
            "custom" => { "progress" => 75 }
          }
        )

        @workflow_patches["activejob-temporal.workflow-state-v1"] = false

        workflow.execute(payload)

        assert_hash_includes(
          {
            "job_class" => "SampleJob",
            "job_id" => "abc-123",
            "custom" => {}
          },
          workflow.handle_dynamic_query("state")
        )
      end
    end

    describe "when chain metadata is present" do
      it "executes chained activities sequentially with each previous result as the next raw argument" do
        payload = base_payload.merge(
          "chain" => [
            {
              "job_class" => "SecondChainJob",
              "job_id" => "abc-123:chain:1",
              "queue_name" => "reporting",
              "arguments" => [],
              "activity_task_queue" => "reporting",
              "default_activity_options" => base_payload.fetch("default_activity_options"),
              "retry_policy" => retry_policy_hash
            },
            {
              "job_class" => "ThirdChainJob",
              "job_id" => "abc-123:chain:2",
              "queue_name" => "default",
              "arguments" => [],
              "activity_task_queue" => "priority_reports",
              "default_activity_options" => base_payload.fetch("default_activity_options"),
              "retry_policy" => retry_policy_hash
            }
          ]
        )
        calls = []
        results = %w[first-result second-result third-result]
        @execute_activity_handler = proc do |*args, **options|
          calls << [args, options]
          results.shift
        end

        assert_equal "third-result", workflow.execute(payload)

        assert_equal(
          [
            ActiveJob::Temporal::Activities::AjRunnerActivity,
            ActiveJob::Temporal::Activities::AjRunnerActivity,
            ActiveJob::Temporal::Activities::AjRunnerActivity
          ],
          calls.map { |args, _options| args.first }
        )
        assert_equal [ActiveJob::Temporal::Activities::AjRunnerActivity, payload], calls[0][0]
        assert_hash_includes(
          {
            "job_class" => "SecondChainJob",
            "queue_name" => "reporting",
            "arguments" => ["first-result"]
          },
          calls[1][0][1]
        )
        assert_equal ["first-result"], calls[1][0][2]
        assert_equal "reporting", calls[1][1][:task_queue]
        assert_hash_includes(
          {
            "job_class" => "ThirdChainJob",
            "activity_task_queue" => "priority_reports",
            "arguments" => ["second-result"]
          },
          calls[2][0][1]
        )
        assert_equal ["second-result"], calls[2][0][2]
        assert_equal "priority_reports", calls[2][1][:task_queue]
      end

      it "dispatches external activity and workflow chain steps with the previous result as input" do
        payload = base_payload.merge(
          "chain" => [
            {
              "temporal_operation" => "activity",
              "temporal_type" => "payments.AuthorizePayment",
              "options" => {
                "task_queue" => "payments-kotlin",
                "start_to_close_timeout" => 30.0
              }
            },
            {
              "temporal_operation" => "workflow",
              "temporal_type" => "inventory.ReserveInventoryWorkflow",
              "options" => {
                "task_queue" => "inventory-kotlin",
                "run_timeout" => 300.0
              }
            },
            {
              "job_class" => "CompleteCheckoutJob",
              "job_id" => "abc-123:chain:3",
              "queue_name" => "default",
              "arguments" => [],
              "activity_task_queue" => "default",
              "default_activity_options" => base_payload.fetch("default_activity_options"),
              "retry_policy" => retry_policy_hash
            }
          ]
        )
        @execute_activity_handler = proc do |activity, *args, **_options|
          if activity == ActiveJob::Temporal::Activities::AjRunnerActivity &&
             args.first.fetch("job_class") == "SampleJob"
            "payment-request"
          elsif activity == "payments.AuthorizePayment"
            "authorization"
          else
            "complete"
          end
        end
        @execute_child_workflow_handler = proc do |_workflow_type, *_args, **_options|
          "reservation"
        end

        assert_equal "complete", workflow.execute(payload)

        recorded_activity_calls = activity_calls.map do |call|
          [call.arguments[0], call.arguments.drop(1), call.keywords]
        end
        recorded_workflow_calls =
          child_workflow_calls.map { |call| [call.arguments[0], call.arguments.drop(1), call.keywords] }

        assert_equal "payments.AuthorizePayment", recorded_activity_calls[1][0]
        assert_equal ["payment-request"], recorded_activity_calls[1][1]
        assert_hash_includes(
          {
            task_queue: "payments-kotlin",
            start_to_close_timeout: 30.0
          },
          recorded_activity_calls[1][2]
        )
        assert_equal "inventory.ReserveInventoryWorkflow", recorded_workflow_calls.first[0]
        assert_equal ["authorization"], recorded_workflow_calls.first[1]
        assert_hash_includes(
          {
            task_queue: "inventory-kotlin",
            run_timeout: 300.0
          },
          recorded_workflow_calls.first[2]
        )
        assert_equal ActiveJob::Temporal::Activities::AjRunnerActivity, recorded_activity_calls.last.first
        assert_hash_includes(
          {
            "job_class" => "CompleteCheckoutJob",
            "arguments" => ["reservation"]
          },
          recorded_activity_calls.last[1][0]
        )
        assert_equal ["reservation"], recorded_activity_calls.last[1][1]
      end

      it "stops before later chain steps when a chained activity fails" do
        error = Temporalio::Error::ActivityError.new(
          "activity failed",
          scheduled_event_id: 1,
          started_event_id: 2,
          identity: "worker-1",
          activity_type: "AjRunnerActivity",
          activity_id: "activity-1",
          retry_state: Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
        )
        payload = base_payload.merge(
          "chain" => [
            { "job_class" => "SecondChainJob", "options" => {} },
            { "job_class" => "ThirdChainJob", "options" => {} }
          ]
        )
        calls = []
        @execute_activity_handler = proc do |*args, **_options|
          calls << args
          raise error if calls.length == 2

          "first-result"
        end

        raised = assert_raises(Temporalio::Error::ActivityError) { workflow.execute(payload) }

        assert_same error, raised
        assert_equal 2, calls.length
        assert_hash_includes({ "job_class" => "SecondChainJob" }, calls.dig(1, 1))
      end

      it "dead-letters a failed chain step with chain step metadata" do
        error = Temporalio::Error::ActivityError.new(
          "activity failed",
          scheduled_event_id: 1,
          started_event_id: 2,
          identity: "worker-1",
          activity_type: "AjRunnerActivity",
          activity_id: "activity-1",
          retry_state: Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
        )
        application_error = Temporalio::Error::ApplicationError.new(
          "permanent failure",
          type: "StandardError"
        )
        payload = base_payload.merge(
          "dead_letter" => {
            "queue" => "failed_jobs",
            "after_attempts" => 3,
            "auto_discard_after_seconds" => 86_400.0,
            "job_class" => "SampleJob",
            "job_id" => "abc-123",
            "queue_name" => "default"
          },
          "chain" => [
            {
              "job_class" => "SecondChainJob",
              "job_id" => "abc-123:chain:1",
              "queue_name" => "reporting",
              "arguments" => [],
              "activity_task_queue" => "priority_reports",
              "default_activity_options" => base_payload.fetch("default_activity_options"),
              "retry_policy" => retry_policy_hash,
              "dead_letter" => {
                "queue" => "failed_jobs",
                "after_attempts" => 3,
                "auto_discard_after_seconds" => 86_400.0,
                "job_class" => "SecondChainJob",
                "job_id" => "abc-123:chain:1",
                "queue_name" => "reporting",
                "task_queue" => "priority_reports"
              }
            }
          ]
        )
        calls = []
        call_recorded_method(error, :cause, returns: application_error)
        @workflow_now = Time.utc(2026, 5, 21, 10, 0, 0)
        @execute_activity_handler = proc do |*args, **_options|
          calls << args
          raise error if calls.length == 2

          "first-result"
        end

        raised = assert_raises(Temporalio::Error::ActivityError) { workflow.execute(payload) }

        assert_same error, raised
        dead_letter_call = start_child_workflow_calls.last
        assert_equal ActiveJob::Temporal::Workflows::DeadLetterWorkflow, dead_letter_call.arguments[0]
        dead_letter_entry = dead_letter_call.arguments[1]
        assert_hash_includes({ "id" => "ajdlq:SecondChainJob:abc-123:chain:1" }, dead_letter_entry)
        assert_hash_includes(
          {
            "job_class" => "SecondChainJob",
            "job_id" => "abc-123:chain:1",
            "queue_name" => "reporting"
          },
          dead_letter_entry.fetch("payload")
        )
        assert_hash_includes(
          {
            "job_class" => "SecondChainJob",
            "job_id" => "abc-123:chain:1",
            "original_queue_name" => "reporting",
            "original_task_queue" => "priority_reports",
            "auto_discard_after_seconds" => 86_400.0
          },
          dead_letter_entry.fetch("metadata")
        )
        assert_equal(
          {
            id: "ajdlq:SecondChainJob:abc-123:chain:1",
            task_queue: "failed_jobs",
            parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON
          },
          dead_letter_call.keywords
        )
      end

      it "logs skipped dead-lettering when a failed chain step has a blank DLQ queue" do
        error = Temporalio::Error::ActivityError.new(
          "activity failed",
          scheduled_event_id: 1,
          started_event_id: 2,
          identity: "worker-1",
          activity_type: "AjRunnerActivity",
          activity_id: "activity-1",
          retry_state: Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
        )
        payload = base_payload.merge(
          "chain" => [
            {
              "job_class" => "SecondChainJob",
              "job_id" => "abc-123:chain:1",
              "queue_name" => "reporting",
              "arguments" => [],
              "activity_task_queue" => "priority_reports",
              "default_activity_options" => base_payload.fetch("default_activity_options"),
              "retry_policy" => retry_policy_hash,
              "dead_letter" => {
                "queue" => nil,
                "after_attempts" => 3,
                "job_class" => "SecondChainJob",
                "job_id" => "abc-123:chain:1",
                "queue_name" => "reporting",
                "task_queue" => "priority_reports"
              }
            }
          ]
        )
        calls = []
        @execute_activity_handler = proc do |*args, **_options|
          calls << args
          raise error if calls.length == 2

          "first-result"
        end

        raised = assert_raises(Temporalio::Error::ActivityError) { workflow.execute(payload) }

        assert_same error, raised
        assert_empty start_child_workflow_calls
        assert_hash_includes(
          {
            event: "dead_letter_skipped",
            reason: "blank_queue",
            job_class: "SecondChainJob",
            job_id: "abc-123:chain:1",
            queue_name: "reporting",
            retry_state: Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
          },
          @workflow_logger.warn_calls.last
        )
      end
    end

    describe "when child workflow metadata is present" do
      it "starts child workflows, waits for results, and returns a result collection" do
        payload = base_payload.merge(
          "child_workflows" => [
            {
              "job_class" => "ChildWorkflowJob",
              "job_id" => "abc-123:child:1",
              "workflow_id" => "ajwf:ChildWorkflowJob:abc-123:child:1",
              "queue_name" => "children",
              "arguments" => [],
              "activity_task_queue" => "children",
              "workflow_task_queue" => "children",
              "default_activity_options" => base_payload.fetch("default_activity_options"),
              "retry_policy" => retry_policy_hash
            }
          ]
        )
        child_handle = AjWorkflowSpecSupport::ChildWorkflowHandle.new(result: "child-result")
        @execute_activity_handler = proc { "parent-result" }
        @start_child_workflow_handler = proc { child_handle }

        assert_equal(
          {
            "parent_result" => "parent-result",
            "child_results" => [
              {
                "job_class" => "ChildWorkflowJob",
                "job_id" => "abc-123:child:1",
                "workflow_id" => "ajwf:ChildWorkflowJob:abc-123:child:1",
                "result" => "child-result"
              }
            ]
          },
          workflow.execute(payload)
        )
        child_call = start_child_workflow_calls.first
        assert_equal workflow_class, child_call.arguments[0]
        assert_hash_includes(
          {
            "job_class" => "ChildWorkflowJob",
            "job_id" => "abc-123:child:1",
            "arguments" => ["parent-result"]
          },
          child_call.arguments[1]
        )
        assert_equal(
          {
            id: "ajwf:ChildWorkflowJob:abc-123:child:1",
            task_queue: "children",
            parent_close_policy: Temporalio::Workflow::ParentClosePolicy::REQUEST_CANCEL,
            cancellation_type: Temporalio::Workflow::ChildWorkflowCancellationType::WAIT_CANCELLATION_COMPLETED
          },
          child_call.keywords
        )
      end

      it "starts external child workflows with the parent result as input" do
        payload = base_payload.merge(
          "child_workflows" => [
            {
              "job_class" => "ChildWorkflowJob",
              "job_id" => "abc-123:child:1",
              "workflow_id" => "ajwf:ChildWorkflowJob:abc-123:child:1",
              "queue_name" => "children",
              "arguments" => [],
              "activity_task_queue" => "children",
              "workflow_task_queue" => "children",
              "default_activity_options" => base_payload.fetch("default_activity_options"),
              "retry_policy" => retry_policy_hash
            },
            {
              "temporal_operation" => "workflow",
              "temporal_type" => "fulfillment.PrepareShipmentWorkflow",
              "options" => {
                "task_queue" => "fulfillment-kotlin",
                "run_timeout" => 300.0,
                "id" => "shipment-child-1"
              }
            }
          ]
        )
        active_child_handle = AjWorkflowSpecSupport::ChildWorkflowHandle.new(result: "active-child")
        external_child_handle = AjWorkflowSpecSupport::ChildWorkflowHandle.new(result: "external-child")

        @execute_activity_handler = proc { "parent-result" }
        @start_child_workflow_handler = proc do |workflow_type, *_args, **_options|
          workflow_type == workflow_class ? active_child_handle : external_child_handle
        end

        assert_equal(
          {
            "parent_result" => "parent-result",
            "child_results" => [
              {
                "job_class" => "ChildWorkflowJob",
                "job_id" => "abc-123:child:1",
                "workflow_id" => "ajwf:ChildWorkflowJob:abc-123:child:1",
                "result" => "active-child"
              },
              {
                "temporal_operation" => "workflow",
                "temporal_type" => "fulfillment.PrepareShipmentWorkflow",
                "workflow_id" => "shipment-child-1",
                "task_queue" => "fulfillment-kotlin",
                "result" => "external-child"
              }
            ]
          },
          workflow.execute(payload)
        )
        external_child_call = start_child_workflow_calls.last
        assert_equal "fulfillment.PrepareShipmentWorkflow", external_child_call.arguments[0]
        assert_equal ["parent-result"], external_child_call.arguments.drop(1)
        assert_hash_includes(
          {
            id: "shipment-child-1",
            task_queue: "fulfillment-kotlin",
            run_timeout: 300.0,
            parent_close_policy: Temporalio::Workflow::ParentClosePolicy::REQUEST_CANCEL,
            cancellation_type: Temporalio::Workflow::ChildWorkflowCancellationType::WAIT_CANCELLATION_COMPLETED
          },
          external_child_call.keywords
        )
      end

      it "passes the child result collection into later chain steps" do
        payload = base_payload.merge(
          "child_workflows" => [
            {
              "job_class" => "ChildWorkflowJob",
              "job_id" => "abc-123:child:1",
              "workflow_id" => "ajwf:ChildWorkflowJob:abc-123:child:1",
              "queue_name" => "children",
              "arguments" => [],
              "activity_task_queue" => "children",
              "workflow_task_queue" => "children",
              "default_activity_options" => base_payload.fetch("default_activity_options"),
              "retry_policy" => retry_policy_hash
            }
          ],
          "chain" => [
            {
              "job_class" => "AfterChildrenJob",
              "job_id" => "abc-123:chain:1",
              "queue_name" => "default",
              "arguments" => [],
              "activity_task_queue" => "default",
              "default_activity_options" => base_payload.fetch("default_activity_options"),
              "retry_policy" => retry_policy_hash
            }
          ]
        )
        child_handle = AjWorkflowSpecSupport::ChildWorkflowHandle.new(result: "child-result")
        results = %w[parent-result chain-result]
        @start_child_workflow_handler = proc { child_handle }
        @execute_activity_handler = proc { results.shift }

        assert_equal "chain-result", workflow.execute(payload)

        activity_class, activity_payload, raw_arguments = last_activity_call.arguments
        expected_chain_argument = {
          "parent_result" => "parent-result",
          "child_results" => [
            {
              "job_class" => "ChildWorkflowJob",
              "job_id" => "abc-123:child:1",
              "workflow_id" => "ajwf:ChildWorkflowJob:abc-123:child:1",
              "result" => "child-result"
            }
          ]
        }

        assert_equal ActiveJob::Temporal::Activities::AjRunnerActivity, activity_class
        assert_hash_includes(
          {
            "job_class" => "AfterChildrenJob",
            "arguments" => [expected_chain_argument]
          },
          activity_payload
        )
        assert_equal [expected_chain_argument], raw_arguments
      end
    end

    describe "when dependencies are present" do
      let(:dependency_payload) do
        base_payload.merge(
          "dependencies" => [
            {
              "job_id" => "parent-123",
              "workflow_id" => "ajwf:DependencyParentJob:parent-123"
            }
          ],
          "dependency_failure_policy" => "fail"
        )
      end

      it "checks dependencies before executing the job activity" do
        calls = []
        @execute_activity_handler = proc do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          if activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
            [
              {
                "job_id" => "parent-123",
                "workflow_id" => "ajwf:DependencyParentJob:parent-123",
                "state" => "completed"
              }
            ]
          else
            :activity_result
          end
        end

        workflow.execute(dependency_payload)

        assert_equal(
          [
            ActiveJob::Temporal::Activities::DependencyStatusActivity,
            ActiveJob::Temporal::Activities::AjRunnerActivity
          ],
          calls.map(&:first)
        )
        assert_equal [dependency_payload.fetch("dependencies")], calls.first[1]
        assert_equal workflow_class::DEPENDENCY_CHECK_ACTIVITY_TIMEOUT, calls.first[2][:schedule_to_close_timeout]
        assert_equal workflow_class::DEPENDENCY_CHECK_ACTIVITY_TIMEOUT, calls.first[2][:start_to_close_timeout]
        assert_equal 1, calls.first[2][:retry_policy].max_attempts
      end

      it "sleeps durably and rechecks while dependencies are pending" do
        statuses = [
          [{ "job_id" => "parent-123", "state" => "running" }],
          [{ "job_id" => "parent-123", "state" => "completed" }]
        ]
        calls = []
        @execute_activity_handler = proc do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          if activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
            statuses.shift
          else
            :activity_result
          end
        end

        workflow.execute(dependency_payload)

        assert_equal [workflow_class::DEPENDENCY_WAIT_INTERVAL], sleep_durations
        dependency_checks = calls.count do |activity_class, _args, _options|
          activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
        end
        assert_equal 2, dependency_checks
        assert_equal ActiveJob::Temporal::Activities::AjRunnerActivity, calls.last.first
      end

      it "backs off dependency checks while dependencies keep running" do
        payload = dependency_payload.merge(
          "dependency_wait" => {
            "initial_interval" => 5.0,
            "max_interval" => 20.0,
            "timeout" => 120.0
          }
        )
        statuses = [
          [{ "job_id" => "parent-123", "state" => "running" }],
          [{ "job_id" => "parent-123", "state" => "running" }],
          [{ "job_id" => "parent-123", "state" => "running" }],
          [{ "job_id" => "parent-123", "state" => "completed" }]
        ]
        @execute_activity_handler = proc do |activity_class, *_args, **_options|
          if activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
            statuses.shift
          else
            :activity_result
          end
        end

        workflow.execute(payload)

        timeout_call = timeout_calls.last
        assert_equal 120.0, timeout_call.arguments[0]
        assert_equal Timeout::Error, timeout_call.arguments[1]
        assert_match(/dependency wait timed out/, timeout_call.arguments[2])
        assert_equal({ summary: "Dependency wait timeout" }, timeout_call.keywords)
        assert_equal [5.0, 10.0, 20.0], sleep_durations
      end

      it "uses the remaining dependency wait timeout after continue-as-new" do
        current_time = Time.utc(2024, 1, 1, 12, 0, 30)
        payload = dependency_payload.merge(
          "dependency_wait" => { "timeout" => 60.0 },
          "workflow_state" => {
            "dependency_wait" => {
              "deadline_at" => Time.utc(2024, 1, 1, 12, 1, 0).iso8601
            }
          }
        )
        @workflow_now = current_time
        @execute_activity_handler = proc do |activity_class, *_args, **_options|
          if activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
            [{ "job_id" => "parent-123", "state" => "completed" }]
          else
            :activity_result
          end
        end

        workflow.execute(payload)

        timeout_call = timeout_calls.last
        assert_equal 30.0, timeout_call.arguments[0]
        assert_equal Timeout::Error, timeout_call.arguments[1]
        assert_match(/dependency wait timed out/, timeout_call.arguments[2])
        assert_equal({ summary: "Dependency wait timeout" }, timeout_call.keywords)
      end

      it "carries dependency wait deadline when continuing as new while waiting" do
        current_time = Time.utc(2024, 1, 1, 12, 0, 0)
        continue_error = StandardError.new("continue as new")
        payload = dependency_payload.merge(
          "continue_as_new" => { "history_event_threshold" => 1 },
          "dependency_wait" => {
            "initial_interval" => 5.0,
            "timeout" => 60.0
          }
        )

        @workflow_now = current_time
        workflow_history_lengths(0, 0, 1)
        continue_as_new_recorder =
          call_recorded_method(Temporalio::Workflow::ContinueAsNewError, :new, returns: continue_error)
        @execute_activity_handler = proc do |activity_class, *_args, **_options|
          if activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
            [{ "job_id" => "parent-123", "state" => "running" }]
          else
            :activity_result
          end
        end

        error = assert_raises(StandardError) { workflow.execute(payload) }

        assert_same continue_error, error
        dependency_wait_state = continue_as_new_recorder.calls_for(:new).last.arguments.first.dig(
          "workflow_state",
          "dependency_wait"
        )
        assert_hash_includes(
          {
            "deadline_at" => Time.utc(2024, 1, 1, 12, 1, 0).iso8601,
            "current_interval" => 5.0,
            "not_found_counts" => {}
          },
          dependency_wait_state
        )
      end

      it "fails when running dependencies exceed the dependency wait timeout" do
        payload = dependency_payload.merge("dependency_wait" => { "timeout" => 30.0 })
        @timeout_handler = proc do |_duration, *_args, **_options, &_block|
          raise Timeout::Error, "dependency wait timed out"
        end

        error = assert_raises(Temporalio::Error::ApplicationError) { workflow.execute(payload) }

        assert_match(/timed_out/, error.message)
        timeout_call = timeout_calls.last
        assert_equal 30.0, timeout_call.arguments[0]
        assert_equal Timeout::Error, timeout_call.arguments[1]
        assert_match(/dependency wait timed out/, timeout_call.arguments[2])
        assert_equal({ summary: "Dependency wait timeout" }, timeout_call.keywords)
      end

      it "continues when a dependency has continued as new" do
        calls = []
        @execute_activity_handler = proc do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          if activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
            [{ "job_id" => "parent-123", "state" => "continued_as_new" }]
          else
            :activity_result
          end
        end

        workflow.execute(dependency_payload)

        assert_equal(
          [
            ActiveJob::Temporal::Activities::DependencyStatusActivity,
            ActiveJob::Temporal::Activities::AjRunnerActivity
          ],
          calls.map(&:first)
        )
      end

      it "fails before executing the job activity when a dependency fails" do
        calls = []
        @execute_activity_handler = proc do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          [
            {
              "job_id" => "parent-123",
              "workflow_id" => "ajwf:DependencyParentJob:parent-123",
              "state" => "failed"
            }
          ]
        end

        error = assert_raises(Temporalio::Error::ApplicationError) { workflow.execute(dependency_payload) }

        assert_match(/Job dependency failed/, error.message)
        assert_equal [ActiveJob::Temporal::Activities::DependencyStatusActivity], calls.map(&:first)
      end

      it "continues when failed dependencies are ignored" do
        payload = dependency_payload.merge("dependency_failure_policy" => "ignore")
        calls = []
        @execute_activity_handler = proc do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          if activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
            [{ "job_id" => "parent-123", "state" => "failed" }]
          else
            :activity_result
          end
        end

        workflow.execute(payload)

        assert_equal(
          [
            ActiveJob::Temporal::Activities::DependencyStatusActivity,
            ActiveJob::Temporal::Activities::AjRunnerActivity
          ],
          calls.map(&:first)
        )
      end

      it "fails after a missing dependency stays missing" do
        stub_const("ActiveJob::Temporal::Workflows::WorkflowDependencies::DEPENDENCY_NOT_FOUND_MAX_CHECKS", 2)
        calls = []
        @execute_activity_handler = proc do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          [{ "job_id" => "parent-123", "state" => "not_found" }]
        end

        error = assert_raises(Temporalio::Error::ApplicationError) { workflow.execute(dependency_payload) }

        assert_match(/parent-123: not_found/, error.message)
        assert_equal [workflow_class::DEPENDENCY_WAIT_INTERVAL], sleep_durations
        assert_equal(
          [
            ActiveJob::Temporal::Activities::DependencyStatusActivity,
            ActiveJob::Temporal::Activities::DependencyStatusActivity
          ],
          calls.map(&:first)
        )
      end

      it "resets missing dependency checks when a dependency reappears" do
        stub_const("ActiveJob::Temporal::Workflows::WorkflowDependencies::DEPENDENCY_NOT_FOUND_MAX_CHECKS", 2)
        dependency_statuses = [
          [{ "job_id" => "parent-123", "state" => "not_found" }],
          [
            {
              "job_id" => "parent-123",
              "workflow_id" => "ajwf:DependencyParentJob:parent-123",
              "state" => "running"
            }
          ],
          [{ "job_id" => "parent-123", "state" => "not_found" }],
          [
            {
              "job_id" => "parent-123",
              "workflow_id" => "ajwf:DependencyParentJob:parent-123",
              "state" => "completed"
            }
          ]
        ]
        calls = []
        @execute_activity_handler = proc do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          if activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
            dependency_statuses.shift
          else
            :activity_result
          end
        end

        workflow.execute(dependency_payload)

        assert_equal(
          [
            ActiveJob::Temporal::Activities::DependencyStatusActivity,
            ActiveJob::Temporal::Activities::DependencyStatusActivity,
            ActiveJob::Temporal::Activities::DependencyStatusActivity,
            ActiveJob::Temporal::Activities::DependencyStatusActivity,
            ActiveJob::Temporal::Activities::AjRunnerActivity
          ],
          calls.map(&:first)
        )
      end

      it "continues after a missing dependency stays missing when failures are ignored" do
        stub_const("ActiveJob::Temporal::Workflows::WorkflowDependencies::DEPENDENCY_NOT_FOUND_MAX_CHECKS", 2)
        payload = dependency_payload.merge("dependency_failure_policy" => "ignore")
        calls = []
        @execute_activity_handler = proc do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          if activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
            [{ "job_id" => "parent-123", "state" => "not_found" }]
          else
            :activity_result
          end
        end

        workflow.execute(payload)

        assert_equal(
          [
            ActiveJob::Temporal::Activities::DependencyStatusActivity,
            ActiveJob::Temporal::Activities::DependencyStatusActivity,
            ActiveJob::Temporal::Activities::AjRunnerActivity
          ],
          calls.map(&:first)
        )
      end
    end

    it "does not read process configuration during workflow execution" do
      call_recorded_method(
        ActiveJob::Temporal,
        :config,
        raises: RuntimeError.new("workflow must use payload data")
      )

      workflow.execute(base_payload)

      refute_empty activity_calls
    end

    describe "when rate limits are present" do
      let(:rate_limited_payload) do
        base_payload.merge(
          "rate_limits" => [
            { "limit" => 100, "interval" => 1.0, "key" => "global" }
          ]
        )
      end

      it "checks rate limits before executing the job activity" do
        calls = []
        @execute_activity_handler = proc do |activity_class, payload_arg, **options|
          calls << [activity_class, payload_arg, options]
          activity_class == ActiveJob::Temporal::Activities::RateLimitActivity ? 0.0 : :activity_result
        end

        workflow.execute(rate_limited_payload)

        assert_equal(
          [
            ActiveJob::Temporal::Activities::RateLimitActivity,
            ActiveJob::Temporal::Activities::AjRunnerActivity
          ],
          calls.map(&:first)
        )
        assert_equal rate_limited_payload, calls.first[1]
        assert_equal workflow_class::RATE_LIMIT_ACTIVITY_TIMEOUT, calls.first[2][:schedule_to_close_timeout]
        assert_equal workflow_class::RATE_LIMIT_ACTIVITY_TIMEOUT, calls.first[2][:start_to_close_timeout]
        assert_equal 1, calls.first[2][:retry_policy].max_attempts
      end

      it "sleeps durably and rechecks when the limiter returns a wait time" do
        waits = [3.5, 0.0]
        @execute_activity_handler = proc do |activity_class, _payload_arg, **_options|
          activity_class == ActiveJob::Temporal::Activities::RateLimitActivity ? waits.shift : :activity_result
        end

        workflow.execute(rate_limited_payload)

        assert_equal [3.5], sleep_durations
        rate_limit_calls = activity_calls.select do |call|
          call.arguments == [ActiveJob::Temporal::Activities::RateLimitActivity, rate_limited_payload]
        end
        assert_equal 2, rate_limit_calls.length
      end

      it "can run rate limit checks as local activities while job execution stays remote" do
        payload = rate_limited_payload.merge("local_activity_helpers" => ["rate_limit"])
        waits = [1.0, 0.0]

        @execute_local_activity_handler = proc do |activity_class, payload_arg, **options|
          assert_equal ActiveJob::Temporal::Activities::RateLimitActivity, activity_class
          assert_equal payload, payload_arg
          assert_equal workflow_class::RATE_LIMIT_ACTIVITY_TIMEOUT, options[:start_to_close_timeout]
          waits.shift
        end

        workflow.execute(payload)

        assert_equal 2, local_activity_calls.length
        activity_call = last_activity_call
        assert_equal ActiveJob::Temporal::Activities::AjRunnerActivity, activity_call.arguments[0]
        assert_equal payload, activity_call.arguments[1]
      end

      it "falls back to standard helper activities when the local activity patch is disabled" do
        payload = rate_limited_payload.merge("local_activity_helpers" => ["rate_limit"])
        @workflow_patches["activejob-temporal.local-activity-helpers-v1"] = false
        @execute_activity_handler = proc do |activity_class, _payload_arg, **_options|
          activity_class == ActiveJob::Temporal::Activities::RateLimitActivity ? 0.0 : :activity_result
        end

        workflow.execute(payload)

        assert_empty local_activity_calls
        rate_limit_call = activity_calls.find do |call|
          call.arguments == [ActiveJob::Temporal::Activities::RateLimitActivity, payload]
        end
        refute_nil rate_limit_call
      end
    end

    describe "when temporal_options are present in payload" do
      it "overrides timeout values with per-job temporal_options" do
        temporal_options = {
          start_to_close_timeout: 7200.0,
          heartbeat_timeout: 30.0
        }
        payload = base_payload.merge("temporal_options" => temporal_options)

        workflow.execute(payload)

        options = last_activity_call.keywords

        assert_equal 7200.0, options[:start_to_close_timeout]
        assert_equal 30.0, options[:heartbeat_timeout]
      end

      it "applies all four timeout types when specified" do
        temporal_options = {
          start_to_close_timeout: 3600.0,
          schedule_to_close_timeout: 7200.0,
          schedule_to_start_timeout: 300.0,
          heartbeat_timeout: 30.0
        }
        payload = base_payload.merge("temporal_options" => temporal_options)

        workflow.execute(payload)

        options = last_activity_call.keywords

        assert_equal 3600.0, options[:start_to_close_timeout]
        assert_equal 7200.0, options[:schedule_to_close_timeout]
        assert_equal 300.0, options[:schedule_to_start_timeout]
        assert_equal 30.0, options[:heartbeat_timeout]
      end

      it "handles symbol keys in temporal_options" do
        temporal_options = {
          start_to_close_timeout: 1800.0
        }
        payload = base_payload.merge(temporal_options: temporal_options)

        workflow.execute(payload)

        assert_equal 1800.0, last_activity_call.keywords[:start_to_close_timeout]
      end

      it "uses default activity options when temporal_options are not present" do
        workflow.execute(base_payload)

        options = last_activity_call.keywords

        assert_equal activity_timeout, options[:start_to_close_timeout]
        assert_nil options[:heartbeat_timeout]
      end
    end

    describe "when default activity options are present" do
      let(:payload_with_defaults) do
        base_payload.merge(
          "default_activity_options" => {
            "start_to_close_timeout" => activity_timeout,
            "heartbeat_timeout" => 60,
            "schedule_to_start_timeout" => 120
          }
        )
      end

      it "applies default activity options" do
        workflow.execute(payload_with_defaults)

        options = last_activity_call.keywords

        assert_equal activity_timeout, options[:start_to_close_timeout]
        assert_equal 60, options[:heartbeat_timeout]
        assert_equal 120, options[:schedule_to_start_timeout]
      end

      it "allows per-job temporal_options to override global defaults" do
        temporal_options = {
          heartbeat_timeout: 15.0
        }
        payload = payload_with_defaults.merge("temporal_options" => temporal_options)

        workflow.execute(payload)

        options = last_activity_call.keywords

        assert_equal 15.0, options[:heartbeat_timeout]
        assert_equal 120, options[:schedule_to_start_timeout]
      end
    end

    describe "when workflow interactions are present" do
      it "supports built-in pause, resume, paused, and state handlers" do
        payload = base_payload.merge(
          "workflow_interactions" => {
            "signals" => %w[pause resume],
            "queries" => %w[paused state]
          }
        )

        workflow.execute(payload)

        refute workflow.handle_dynamic_query("paused")

        workflow.handle_dynamic_signal("pause")

        assert workflow.handle_dynamic_query("paused")
        assert_hash_includes(
          {
            "job_class" => "SampleJob",
            "job_id" => "abc-123",
            "paused" => true
          },
          workflow.handle_dynamic_query("state")
        )

        workflow.handle_dynamic_signal("resume")

        refute workflow.handle_dynamic_query("paused")
      end

      it "waits while paused before executing the job activity" do
        @wait_condition_handler = proc do |&condition|
          workflow.handle_dynamic_signal("resume")
          condition.call
        end

        workflow.handle_dynamic_signal("pause", "manual hold")
        workflow.execute(base_payload)

        refute_empty @wait_condition_recorder.calls_for(:wait_condition)
        activity_call = last_activity_call
        assert_equal ActiveJob::Temporal::Activities::AjRunnerActivity, activity_call.arguments[0]
        assert_equal base_payload, activity_call.arguments[1]
        refute workflow.handle_dynamic_query("paused")
      end

      it "routes declared custom interactions to the ActiveJob handlers" do
        signal_handler = lambda do |state, value|
          state["progress"] = value
        end
        query_handler = lambda do |state|
          state.fetch("progress", 0)
        end
        job_class = Class.new do
          define_singleton_method(:temporal_signal_handlers) { { "progress" => signal_handler } }
          define_singleton_method(:temporal_query_handlers) { { "progress" => query_handler } }
        end
        stub_const("SampleJob", job_class)
        payload = base_payload.merge(
          "workflow_interactions" => {
            "job_class" => "SampleJob",
            "signals" => ["progress"],
            "queries" => ["progress"]
          }
        )

        workflow.execute(payload)
        workflow.handle_dynamic_signal("progress", 75)

        assert_equal 75, workflow.handle_dynamic_query("progress")
      end

      it "routes declared custom updates to the ActiveJob handlers and returns their result" do
        update_handler = lambda do |state, completed, total|
          state["progress"] = { "completed" => completed, "total" => total }
          state["progress"]
        end
        query_handler = lambda do |state|
          state["progress"]
        end
        job_class = Class.new do
          define_singleton_method(:temporal_update_handlers) { { "set_progress" => update_handler } }
          define_singleton_method(:temporal_query_handlers) { { "progress" => query_handler } }
        end
        stub_const("SampleJob", job_class)
        payload = base_payload.merge(
          "workflow_interactions" => {
            "job_class" => "SampleJob",
            "updates" => ["set_progress"],
            "queries" => ["progress"]
          }
        )

        workflow.execute(payload)
        result = workflow.handle_dynamic_update("set_progress", 450, 1_000)

        assert_equal({ "completed" => 450, "total" => 1_000 }, result)
        assert_equal(
          { "completed" => 450, "total" => 1_000 },
          workflow.handle_dynamic_query("progress")
        )
        state = workflow.handle_dynamic_query("state")

        assert_includes state.fetch("updates"), "set_progress"
        assert_hash_includes({ "args" => [450, 1_000] }, state.fetch("updates").fetch("set_progress"))
      end

      it "routes buffered custom signals after workflow interactions are configured" do
        signal_handler = lambda do |state, value|
          state["progress"] = value
        end
        query_handler = lambda do |state|
          state.fetch("progress", 0)
        end
        job_class = Class.new do
          define_singleton_method(:temporal_signal_handlers) { { "progress" => signal_handler } }
          define_singleton_method(:temporal_query_handlers) { { "progress" => query_handler } }
        end
        stub_const("SampleJob", job_class)
        payload = base_payload.merge(
          "workflow_interactions" => {
            "job_class" => "SampleJob",
            "signals" => ["progress"],
            "queries" => ["progress"]
          }
        )

        workflow.handle_dynamic_signal("progress", 75)
        workflow.execute(payload)

        assert_equal 75, workflow.handle_dynamic_query("progress")
      end

      it "rejects undeclared custom interactions" do
        payload = base_payload.merge(
          "workflow_interactions" => {
            "signals" => ["progress"],
            "queries" => ["progress"]
          }
        )

        workflow.execute(payload)

        error = assert_raises(ArgumentError) { workflow.handle_dynamic_signal("missing") }
        assert_match(/Unknown workflow signal/, error.message)

        error = assert_raises(ArgumentError) { workflow.handle_dynamic_query("missing") }
        assert_match(/Unknown workflow query/, error.message)

        error = assert_raises(ArgumentError) { workflow.handle_dynamic_update("missing") }
        assert_match(/Unknown workflow update/, error.message)
      end
    end

    describe "when legacy payloads omit default activity options" do
      it "falls back to the library default timeout" do
        payload = base_payload.except("default_activity_options")

        workflow.execute(payload)

        assert_equal activity_timeout, last_activity_call.keywords[:start_to_close_timeout]
      end
    end

    describe "when activity retries are exhausted and dead letter metadata is present" do
      it "starts a dead letter workflow on the configured DLQ task queue" do
        error = Temporalio::Error::ActivityError.new(
          "activity failed",
          scheduled_event_id: 1,
          started_event_id: 2,
          identity: "worker-1",
          activity_type: "AjRunnerActivity",
          activity_id: "activity-1",
          retry_state: Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
        )
        application_error = Temporalio::Error::ApplicationError.new(
          "permanent failure",
          type: "StandardError"
        )
        payload = base_payload.merge(
          "dead_letter" => {
            "queue" => "failed_jobs",
            "after_attempts" => 3,
            "auto_discard_after_seconds" => 86_400.0,
            "job_class" => "SampleJob",
            "job_id" => "abc-123",
            "queue_name" => "default"
          }
        )
        call_recorded_method(error, :cause, returns: application_error)
        @workflow_now = Time.utc(2026, 5, 21, 10, 0, 0)
        @execute_activity_handler = proc { raise error }

        raised = assert_raises(Temporalio::Error::ActivityError) { workflow.execute(payload) }

        assert_same error, raised
        dead_letter_call = start_child_workflow_calls.last
        assert_equal ActiveJob::Temporal::Workflows::DeadLetterWorkflow, dead_letter_call.arguments[0]
        dead_letter_entry = dead_letter_call.arguments[1]
        assert_hash_includes(
          {
            "id" => "ajdlq:SampleJob:abc-123",
            "state" => "pending",
            "payload" => payload
          },
          dead_letter_entry
        )
        assert_hash_includes(
          {
            "job_class" => "SampleJob",
            "job_id" => "abc-123",
            "original_queue_name" => "default",
            "original_task_queue" => "default",
            "workflow_id" => "ajwf:SampleJob:abc-123",
            "auto_discard_after_seconds" => 86_400.0,
            "failed_at" => "2026-05-21T10:00:00Z"
          },
          dead_letter_entry.fetch("metadata")
        )
        assert_hash_includes(
          {
            "class" => "StandardError",
            "message" => "permanent failure",
            "retry_state" => Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
          },
          dead_letter_entry.fetch("failure")
        )
        assert_equal(
          {
            id: "ajdlq:SampleJob:abc-123",
            task_queue: "failed_jobs",
            parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON
          },
          dead_letter_call.keywords
        )
      end

      it "does not dead-letter non-exhausted activity failures" do
        error = Temporalio::Error::ActivityError.new(
          "activity failed",
          scheduled_event_id: 1,
          started_event_id: 2,
          identity: "worker-1",
          activity_type: "AjRunnerActivity",
          activity_id: "activity-1",
          retry_state: Temporalio::Error::RetryState::IN_PROGRESS
        )
        payload = base_payload.merge(
          "dead_letter" => {
            "queue" => "failed_jobs",
            "job_class" => "SampleJob",
            "job_id" => "abc-123",
            "queue_name" => "default"
          }
        )
        @execute_activity_handler = proc { raise error }

        raised = assert_raises(Temporalio::Error::ActivityError) { workflow.execute(payload) }

        assert_same error, raised
        assert_empty start_child_workflow_calls
      end

      it "does not dead-letter when workflow payload lacks DLQ metadata" do
        error = Temporalio::Error::ActivityError.new(
          "activity failed",
          scheduled_event_id: 1,
          started_event_id: 2,
          identity: "worker-1",
          activity_type: "AjRunnerActivity",
          activity_id: "activity-1",
          retry_state: Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
        )
        @execute_activity_handler = proc { raise error }

        raised = assert_raises(Temporalio::Error::ActivityError) { workflow.execute(base_payload) }

        assert_same error, raised
        assert_empty start_child_workflow_calls
      end

      it "logs skipped dead-lettering when DLQ metadata has a blank queue" do
        error = Temporalio::Error::ActivityError.new(
          "activity failed",
          scheduled_event_id: 1,
          started_event_id: 2,
          identity: "worker-1",
          activity_type: "AjRunnerActivity",
          activity_id: "activity-1",
          retry_state: Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
        )
        payload = base_payload.merge(
          "dead_letter" => {
            "queue" => " ",
            "job_class" => "SampleJob",
            "job_id" => "abc-123",
            "queue_name" => "default"
          }
        )
        @execute_activity_handler = proc { raise error }

        raised = assert_raises(Temporalio::Error::ActivityError) { workflow.execute(payload) }

        assert_same error, raised
        assert_empty start_child_workflow_calls
        assert_hash_includes(
          {
            event: "dead_letter_skipped",
            reason: "blank_queue",
            job_class: "SampleJob",
            job_id: "abc-123",
            queue_name: "default",
            retry_state: Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
          },
          @workflow_logger.warn_calls.last
        )
      end

      it "does not dead-letter rate limit activity failures before the job runs" do
        error = Temporalio::Error::ActivityError.new(
          "activity failed",
          scheduled_event_id: 1,
          started_event_id: 2,
          identity: "worker-1",
          activity_type: "RateLimitActivity",
          activity_id: "activity-1",
          retry_state: Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
        )
        payload = base_payload.merge(
          "rate_limits" => [{ "limit" => 100, "interval" => 1.0, "key" => "global" }],
          "dead_letter" => {
            "queue" => "failed_jobs",
            "job_class" => "SampleJob",
            "job_id" => "abc-123",
            "queue_name" => "default"
          }
        )
        @execute_activity_handler = proc { raise error }

        raised = assert_raises(Temporalio::Error::ActivityError) { workflow.execute(payload) }

        assert_same error, raised
        assert_empty start_child_workflow_calls
      end
    end
  end
end
