# frozen_string_literal: true

require "spec_helper"
require "time"
require "activejob/temporal/workflows/aj_workflow"

module Temporalio
  module Workflow
    class << self
      def now
        @now || Time.utc(2024, 1, 1, 12, 0, 0)
      end

      def sleep(_duration); end

      def execute_activity(*)
        nil
      end

      def wait_condition; end
    end
  end
end

RSpec.describe ActiveJob::Temporal::Workflows::AjWorkflow do
  subject(:workflow) { described_class.new }

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
    allow(Temporalio::Workflow).to receive(:execute_activity).and_return(:activity_result)
    allow(Temporalio::Workflow).to receive(:sleep)
    allow(Temporalio::Workflow).to receive(:start_child_workflow)
    allow(ActiveJob::Temporal::RetryMapper).to receive(:for).and_return({})
  end

  describe "#execute" do
    context "when payload has no scheduled_at" do
      it "invokes the activity immediately" do
        workflow.execute(base_payload)

        expect(Temporalio::Workflow).not_to have_received(:sleep)
        expect(Temporalio::Workflow).to have_received(:execute_activity) do |activity_class, payload, options|
          expect(activity_class).to eq(ActiveJob::Temporal::Activities::AjRunnerActivity)
          expect(payload).to eq(base_payload)
          expect(options[:start_to_close_timeout]).to eq(activity_timeout)
          expect(options[:retry_policy]).to be_a(Temporalio::RetryPolicy)
        end
      end
    end

    context "when payload is scheduled in the future" do
      it "sleeps for the exact delay before executing" do
        current_time = Time.utc(2024, 1, 1, 12, 0, 0)
        scheduled_time = current_time + 300
        payload = base_payload.merge("scheduled_at" => scheduled_time.iso8601)

        allow(Temporalio::Workflow).to receive(:now).and_return(current_time)

        workflow.execute(payload)

        expect(Temporalio::Workflow).to have_received(:sleep).with(be_within(1e-6).of(300.0))
        expect(Temporalio::Workflow).to have_received(:execute_activity) do |activity_class, payload_arg, options|
          expect(activity_class).to eq(ActiveJob::Temporal::Activities::AjRunnerActivity)
          expect(payload_arg).to eq(payload)
          expect(options[:start_to_close_timeout]).to eq(activity_timeout)
          expect(options[:retry_policy]).to be_a(Temporalio::RetryPolicy)
        end
      end
    end

    context "when scheduled_at is in the past" do
      it "skips sleeping and runs immediately" do
        current_time = Time.utc(2024, 1, 1, 12, 0, 0)
        payload = base_payload.merge("scheduled_at" => (current_time - 120).iso8601)

        allow(Temporalio::Workflow).to receive(:now).and_return(current_time)

        workflow.execute(payload)

        expect(Temporalio::Workflow).not_to have_received(:sleep)
        expect(Temporalio::Workflow).to have_received(:execute_activity)
      end
    end

    context "when retry policy metadata is available" do
      it "passes the retry policy through to the activity call" do
        custom_retry_policy = {
          initial_interval: 15.0,
          backoff_coefficient: 1.5,
          maximum_attempts: 5,
          non_retryable_error_types: []
        }
        payload = base_payload.merge("retry_policy" => custom_retry_policy)

        workflow.execute(payload)

        expect(Temporalio::Workflow).to have_received(:execute_activity) do |activity_class, payload_arg, options|
          expect(activity_class).to eq(ActiveJob::Temporal::Activities::AjRunnerActivity)
          expect(payload_arg).to eq(payload)
          expect(options[:start_to_close_timeout]).to eq(activity_timeout)
          expect(options[:retry_policy]).to be_a(Temporalio::RetryPolicy)
        end
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

        expect(Temporalio::Workflow).to have_received(:execute_activity) do |_activity_class, _payload_arg, options|
          retry_policy = options[:retry_policy]
          expect(retry_policy.initial_interval).to eq(1.0)
          expect(retry_policy.backoff_coefficient).to eq(2.0)
          expect(retry_policy.max_interval).to be_nil
          expect(retry_policy.max_attempts).to eq(3)
          expect(retry_policy.non_retryable_error_types).to be_nil
        end
      end
    end

    context "when payload is encrypted" do
      it "passes the encrypted envelope to the activity without reading encryption config" do
        allow(ActiveJob::Temporal).to receive(:config).and_raise("workflow must not decrypt payload")
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

        expect(Temporalio::Workflow).to have_received(:execute_activity) do |activity_class, payload_arg, options|
          expect(activity_class).to eq(ActiveJob::Temporal::Activities::AjRunnerActivity)
          expect(payload_arg).to eq(encrypted_payload)
          expect(options[:start_to_close_timeout]).to eq(activity_timeout)
          expect(options[:retry_policy]).to be_a(Temporalio::RetryPolicy)
        end
      end
    end

    context "when chain metadata is present" do
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
        allow(Temporalio::Workflow).to receive(:execute_activity) do |*args, **options|
          calls << [args, options]
          results.shift
        end

        expect(workflow.execute(payload)).to eq("third-result")

        expect(calls.map { |args, _options| args.first }).to eq([
                                                                  ActiveJob::Temporal::Activities::AjRunnerActivity,
                                                                  ActiveJob::Temporal::Activities::AjRunnerActivity,
                                                                  ActiveJob::Temporal::Activities::AjRunnerActivity
                                                                ])
        expect(calls[0][0]).to eq([
                                    ActiveJob::Temporal::Activities::AjRunnerActivity,
                                    payload
                                  ])
        expect(calls[1][0][1]).to include(
          "job_class" => "SecondChainJob",
          "queue_name" => "reporting",
          "arguments" => ["first-result"]
        )
        expect(calls[1][0][2]).to eq(["first-result"])
        expect(calls[1][1][:task_queue]).to eq("reporting")
        expect(calls[2][0][1]).to include(
          "job_class" => "ThirdChainJob",
          "activity_task_queue" => "priority_reports",
          "arguments" => ["second-result"]
        )
        expect(calls[2][0][2]).to eq(["second-result"])
        expect(calls[2][1][:task_queue]).to eq("priority_reports")
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
        allow(Temporalio::Workflow).to receive(:execute_activity) do |*args, **_options|
          calls << args
          raise error if calls.length == 2

          "first-result"
        end

        expect { workflow.execute(payload) }.to raise_error(error)

        expect(calls.length).to eq(2)
        expect(calls.dig(1, 1)).to include("job_class" => "SecondChainJob")
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
                "job_class" => "SecondChainJob",
                "job_id" => "abc-123:chain:1",
                "queue_name" => "reporting",
                "task_queue" => "priority_reports"
              }
            }
          ]
        )
        calls = []
        allow(error).to receive(:cause).and_return(application_error)
        allow(Temporalio::Workflow).to receive(:now).and_return(Time.utc(2026, 5, 21, 10, 0, 0))
        allow(Temporalio::Workflow).to receive(:execute_activity) do |*args, **_options|
          calls << args
          raise error if calls.length == 2

          "first-result"
        end

        expect { workflow.execute(payload) }.to raise_error(error)

        expect(Temporalio::Workflow).to have_received(:start_child_workflow).with(
          ActiveJob::Temporal::Workflows::DeadLetterWorkflow,
          hash_including(
            "id" => "ajdlq:SecondChainJob:abc-123:chain:1",
            "payload" => hash_including(
              "job_class" => "SecondChainJob",
              "job_id" => "abc-123:chain:1",
              "queue_name" => "reporting"
            ),
            "metadata" => hash_including(
              "job_class" => "SecondChainJob",
              "job_id" => "abc-123:chain:1",
              "original_queue_name" => "reporting",
              "original_task_queue" => "priority_reports"
            )
          ),
          id: "ajdlq:SecondChainJob:abc-123:chain:1",
          task_queue: "failed_jobs",
          parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON
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
        workflow_logger = instance_spy(Logger)
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
        allow(Temporalio::Workflow).to receive(:logger).and_return(workflow_logger)
        allow(Temporalio::Workflow).to receive(:execute_activity) do |*args, **_options|
          calls << args
          raise error if calls.length == 2

          "first-result"
        end

        expect { workflow.execute(payload) }.to raise_error(error)

        expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
        expect(workflow_logger).to have_received(:warn).with(
          hash_including(
            event: "dead_letter_skipped",
            reason: "blank_queue",
            job_class: "SecondChainJob",
            job_id: "abc-123:chain:1",
            queue_name: "reporting",
            retry_state: Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
          )
        )
      end
    end

    context "when dependencies are present" do
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
        allow(Temporalio::Workflow).to receive(:execute_activity) do |activity_class, *args, **options|
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

        expect(calls.map(&:first)).to eq([
                                           ActiveJob::Temporal::Activities::DependencyStatusActivity,
                                           ActiveJob::Temporal::Activities::AjRunnerActivity
                                         ])
        expect(calls.first[1]).to eq([dependency_payload.fetch("dependencies")])
        expect(calls.first[2][:schedule_to_close_timeout]).to eq(described_class::DEPENDENCY_CHECK_ACTIVITY_TIMEOUT)
        expect(calls.first[2][:start_to_close_timeout]).to eq(described_class::DEPENDENCY_CHECK_ACTIVITY_TIMEOUT)
        expect(calls.first[2][:retry_policy].max_attempts).to eq(1)
      end

      it "sleeps durably and rechecks while dependencies are pending" do
        statuses = [
          [{ "job_id" => "parent-123", "state" => "running" }],
          [{ "job_id" => "parent-123", "state" => "completed" }]
        ]
        calls = []
        allow(Temporalio::Workflow).to receive(:execute_activity) do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          if activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
            statuses.shift
          else
            :activity_result
          end
        end

        workflow.execute(dependency_payload)

        expect(Temporalio::Workflow).to have_received(:sleep).with(described_class::DEPENDENCY_WAIT_INTERVAL)
        dependency_checks = calls.count do |activity_class, _args, _options|
          activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
        end
        expect(dependency_checks).to eq(2)
        expect(calls.last.first).to eq(ActiveJob::Temporal::Activities::AjRunnerActivity)
      end

      it "fails before executing the job activity when a dependency fails" do
        calls = []
        allow(Temporalio::Workflow).to receive(:execute_activity) do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          [
            {
              "job_id" => "parent-123",
              "workflow_id" => "ajwf:DependencyParentJob:parent-123",
              "state" => "failed"
            }
          ]
        end

        expect { workflow.execute(dependency_payload) }
          .to raise_error(Temporalio::Error::ApplicationError, /Job dependency failed/)

        expect(calls.map(&:first)).to eq([ActiveJob::Temporal::Activities::DependencyStatusActivity])
      end

      it "continues when failed dependencies are ignored" do
        payload = dependency_payload.merge("dependency_failure_policy" => "ignore")
        calls = []
        allow(Temporalio::Workflow).to receive(:execute_activity) do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          if activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
            [{ "job_id" => "parent-123", "state" => "failed" }]
          else
            :activity_result
          end
        end

        workflow.execute(payload)

        expect(calls.map(&:first)).to eq([
                                           ActiveJob::Temporal::Activities::DependencyStatusActivity,
                                           ActiveJob::Temporal::Activities::AjRunnerActivity
                                         ])
      end

      it "fails after a missing dependency stays missing" do
        stub_const("ActiveJob::Temporal::Workflows::WorkflowDependencies::DEPENDENCY_NOT_FOUND_MAX_CHECKS", 2)
        calls = []
        allow(Temporalio::Workflow).to receive(:execute_activity) do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          [{ "job_id" => "parent-123", "state" => "not_found" }]
        end

        expect { workflow.execute(dependency_payload) }
          .to raise_error(Temporalio::Error::ApplicationError, /parent-123: not_found/)

        expect(Temporalio::Workflow).to have_received(:sleep).with(described_class::DEPENDENCY_WAIT_INTERVAL).once
        expect(calls.map(&:first)).to eq([
                                           ActiveJob::Temporal::Activities::DependencyStatusActivity,
                                           ActiveJob::Temporal::Activities::DependencyStatusActivity
                                         ])
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
        allow(Temporalio::Workflow).to receive(:execute_activity) do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          if activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
            dependency_statuses.shift
          else
            :activity_result
          end
        end

        workflow.execute(dependency_payload)

        expect(calls.map(&:first)).to eq([
                                           ActiveJob::Temporal::Activities::DependencyStatusActivity,
                                           ActiveJob::Temporal::Activities::DependencyStatusActivity,
                                           ActiveJob::Temporal::Activities::DependencyStatusActivity,
                                           ActiveJob::Temporal::Activities::DependencyStatusActivity,
                                           ActiveJob::Temporal::Activities::AjRunnerActivity
                                         ])
      end

      it "continues after a missing dependency stays missing when failures are ignored" do
        stub_const("ActiveJob::Temporal::Workflows::WorkflowDependencies::DEPENDENCY_NOT_FOUND_MAX_CHECKS", 2)
        payload = dependency_payload.merge("dependency_failure_policy" => "ignore")
        calls = []
        allow(Temporalio::Workflow).to receive(:execute_activity) do |activity_class, *args, **options|
          calls << [activity_class, args, options]
          if activity_class == ActiveJob::Temporal::Activities::DependencyStatusActivity
            [{ "job_id" => "parent-123", "state" => "not_found" }]
          else
            :activity_result
          end
        end

        workflow.execute(payload)

        expect(calls.map(&:first)).to eq([
                                           ActiveJob::Temporal::Activities::DependencyStatusActivity,
                                           ActiveJob::Temporal::Activities::DependencyStatusActivity,
                                           ActiveJob::Temporal::Activities::AjRunnerActivity
                                         ])
      end
    end

    it "does not read process configuration during workflow execution" do
      allow(ActiveJob::Temporal).to receive(:config).and_raise("workflow must use payload data")

      workflow.execute(base_payload)

      expect(Temporalio::Workflow).to have_received(:execute_activity)
    end

    context "when rate limits are present" do
      let(:rate_limited_payload) do
        base_payload.merge(
          "rate_limits" => [
            { "limit" => 100, "interval" => 1.0, "key" => "global" }
          ]
        )
      end

      it "checks rate limits before executing the job activity" do
        calls = []
        allow(Temporalio::Workflow).to receive(:execute_activity) do |activity_class, payload_arg, options|
          calls << [activity_class, payload_arg, options]
          activity_class == ActiveJob::Temporal::Activities::RateLimitActivity ? 0.0 : :activity_result
        end

        workflow.execute(rate_limited_payload)

        expect(calls.map(&:first)).to eq([
                                           ActiveJob::Temporal::Activities::RateLimitActivity,
                                           ActiveJob::Temporal::Activities::AjRunnerActivity
                                         ])
        expect(calls.first[1]).to eq(rate_limited_payload)
        expect(calls.first[2][:schedule_to_close_timeout]).to eq(described_class::RATE_LIMIT_ACTIVITY_TIMEOUT)
        expect(calls.first[2][:start_to_close_timeout]).to eq(described_class::RATE_LIMIT_ACTIVITY_TIMEOUT)
        expect(calls.first[2][:retry_policy].max_attempts).to eq(1)
      end

      it "sleeps durably and rechecks when the limiter returns a wait time" do
        waits = [3.5, 0.0]
        allow(Temporalio::Workflow).to receive(:execute_activity) do |activity_class, _payload_arg, _options|
          activity_class == ActiveJob::Temporal::Activities::RateLimitActivity ? waits.shift : :activity_result
        end

        workflow.execute(rate_limited_payload)

        expect(Temporalio::Workflow).to have_received(:sleep).with(3.5)
        expect(Temporalio::Workflow).to have_received(:execute_activity)
          .with(ActiveJob::Temporal::Activities::RateLimitActivity, rate_limited_payload, anything)
          .twice
      end
    end

    context "when temporal_options are present in payload" do
      it "overrides timeout values with per-job temporal_options" do
        temporal_options = {
          start_to_close_timeout: 7200.0,
          heartbeat_timeout: 30.0
        }
        payload = base_payload.merge("temporal_options" => temporal_options)

        workflow.execute(payload)

        expect(Temporalio::Workflow).to have_received(:execute_activity) do |_activity_class, _payload_arg, options|
          expect(options[:start_to_close_timeout]).to eq(7200.0)
          expect(options[:heartbeat_timeout]).to eq(30.0)
        end
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

        expect(Temporalio::Workflow).to have_received(:execute_activity) do |_activity_class, _payload_arg, options|
          expect(options[:start_to_close_timeout]).to eq(3600.0)
          expect(options[:schedule_to_close_timeout]).to eq(7200.0)
          expect(options[:schedule_to_start_timeout]).to eq(300.0)
          expect(options[:heartbeat_timeout]).to eq(30.0)
        end
      end

      it "handles symbol keys in temporal_options" do
        temporal_options = {
          start_to_close_timeout: 1800.0
        }
        payload = base_payload.merge(temporal_options: temporal_options)

        workflow.execute(payload)

        expect(Temporalio::Workflow).to have_received(:execute_activity) do |_activity_class, _payload_arg, options|
          expect(options[:start_to_close_timeout]).to eq(1800.0)
        end
      end

      it "uses default activity options when temporal_options are not present" do
        workflow.execute(base_payload)

        expect(Temporalio::Workflow).to have_received(:execute_activity) do |_activity_class, _payload_arg, options|
          expect(options[:start_to_close_timeout]).to eq(activity_timeout)
          expect(options[:heartbeat_timeout]).to be_nil
        end
      end
    end

    context "when default activity options are present" do
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

        expect(Temporalio::Workflow).to have_received(:execute_activity) do |_activity_class, _payload_arg, options|
          expect(options[:start_to_close_timeout]).to eq(activity_timeout)
          expect(options[:heartbeat_timeout]).to eq(60)
          expect(options[:schedule_to_start_timeout]).to eq(120)
        end
      end

      it "allows per-job temporal_options to override global defaults" do
        temporal_options = {
          heartbeat_timeout: 15.0
        }
        payload = payload_with_defaults.merge("temporal_options" => temporal_options)

        workflow.execute(payload)

        expect(Temporalio::Workflow).to have_received(:execute_activity) do |_activity_class, _payload_arg, options|
          expect(options[:heartbeat_timeout]).to eq(15.0)
          expect(options[:schedule_to_start_timeout]).to eq(120)
        end
      end
    end

    context "when workflow interactions are present" do
      it "supports built-in pause, resume, paused, and state handlers" do
        payload = base_payload.merge(
          "workflow_interactions" => {
            "signals" => %w[pause resume],
            "queries" => %w[paused state]
          }
        )

        workflow.execute(payload)

        expect(workflow.handle_dynamic_query("paused")).to be(false)

        workflow.handle_dynamic_signal("pause")

        expect(workflow.handle_dynamic_query("paused")).to be(true)
        expect(workflow.handle_dynamic_query("state")).to include(
          "job_class" => "SampleJob",
          "job_id" => "abc-123",
          "paused" => true
        )

        workflow.handle_dynamic_signal("resume")

        expect(workflow.handle_dynamic_query("paused")).to be(false)
      end

      it "waits while paused before executing the job activity" do
        allow(Temporalio::Workflow).to receive(:wait_condition) do |&condition|
          workflow.handle_dynamic_signal("resume")
          condition.call
        end

        workflow.handle_dynamic_signal("pause", "manual hold")
        workflow.execute(base_payload)

        expect(Temporalio::Workflow).to have_received(:wait_condition)
        expect(Temporalio::Workflow).to have_received(:execute_activity)
          .with(ActiveJob::Temporal::Activities::AjRunnerActivity, base_payload, anything)
        expect(workflow.handle_dynamic_query("paused")).to be(false)
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

        expect(workflow.handle_dynamic_query("progress")).to eq(75)
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

        expect(workflow.handle_dynamic_query("progress")).to eq(75)
      end

      it "rejects undeclared custom interactions" do
        payload = base_payload.merge(
          "workflow_interactions" => {
            "signals" => ["progress"],
            "queries" => ["progress"]
          }
        )

        workflow.execute(payload)

        expect { workflow.handle_dynamic_signal("missing") }
          .to raise_error(ArgumentError, /Unknown workflow signal/)
        expect { workflow.handle_dynamic_query("missing") }
          .to raise_error(ArgumentError, /Unknown workflow query/)
      end
    end

    context "when legacy payloads omit default activity options" do
      it "falls back to the library default timeout" do
        payload = base_payload.except("default_activity_options")

        workflow.execute(payload)

        expect(Temporalio::Workflow).to have_received(:execute_activity) do |_activity_class, _payload_arg, options|
          expect(options[:start_to_close_timeout]).to eq(activity_timeout)
        end
      end
    end

    context "when activity retries are exhausted and dead letter metadata is present" do
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
            "job_class" => "SampleJob",
            "job_id" => "abc-123",
            "queue_name" => "default"
          }
        )
        allow(error).to receive(:cause).and_return(application_error)
        allow(Temporalio::Workflow).to receive(:now).and_return(Time.utc(2026, 5, 21, 10, 0, 0))
        allow(Temporalio::Workflow).to receive(:execute_activity).and_raise(error)

        expect { workflow.execute(payload) }.to raise_error(error)

        expect(Temporalio::Workflow).to have_received(:start_child_workflow).with(
          ActiveJob::Temporal::Workflows::DeadLetterWorkflow,
          hash_including(
            "id" => "ajdlq:SampleJob:abc-123",
            "state" => "pending",
            "payload" => payload,
            "metadata" => hash_including(
              "job_class" => "SampleJob",
              "job_id" => "abc-123",
              "original_queue_name" => "default",
              "original_task_queue" => "default",
              "workflow_id" => "ajwf:SampleJob:abc-123",
              "failed_at" => "2026-05-21T10:00:00Z"
            ),
            "failure" => hash_including(
              "class" => "StandardError",
              "message" => "permanent failure",
              "retry_state" => Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
            )
          ),
          id: "ajdlq:SampleJob:abc-123",
          task_queue: "failed_jobs",
          parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON
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
        allow(Temporalio::Workflow).to receive(:execute_activity).and_raise(error)

        expect { workflow.execute(payload) }.to raise_error(error)

        expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
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
        allow(Temporalio::Workflow).to receive(:execute_activity).and_raise(error)

        expect { workflow.execute(base_payload) }.to raise_error(error)

        expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
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
        workflow_logger = instance_spy(Logger)
        payload = base_payload.merge(
          "dead_letter" => {
            "queue" => " ",
            "job_class" => "SampleJob",
            "job_id" => "abc-123",
            "queue_name" => "default"
          }
        )
        allow(Temporalio::Workflow).to receive(:logger).and_return(workflow_logger)
        allow(Temporalio::Workflow).to receive(:execute_activity).and_raise(error)

        expect { workflow.execute(payload) }.to raise_error(error)

        expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
        expect(workflow_logger).to have_received(:warn).with(
          hash_including(
            event: "dead_letter_skipped",
            reason: "blank_queue",
            job_class: "SampleJob",
            job_id: "abc-123",
            queue_name: "default",
            retry_state: Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
          )
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
        allow(Temporalio::Workflow).to receive(:execute_activity).and_raise(error)

        expect { workflow.execute(payload) }.to raise_error(error)

        expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
      end
    end
  end
end
