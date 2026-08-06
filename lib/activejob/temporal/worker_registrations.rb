# frozen_string_literal: true

require "temporalio/activity"

module ActiveJob
  module Temporal
    # Resolves which workflows and activities a worker registers, from configuration.
    #
    # By default a worker hosts the built-in ActiveJob workloads. `worker_activities`
    # adds custom activity classes - for example activities invoked by workflows owned
    # by another service, where only the activity name and JSON payloads travel over
    # the wire. Setting `worker_activejob_workloads = false` turns the worker into an
    # activities-only worker that hosts nothing but those custom activities.
    module WorkerRegistrations
      Result = Struct.new(:workflows, :activities, keyword_init: true)

      class << self
        # Configuration validation rejects the nothing-to-register combination up front
        # (see Configuration#validate_worker_registration_settings).
        #
        # @param configuration [ActiveJob::Temporal::Configuration]
        # @return [Result] workflows and activities to pass to Temporalio::Worker
        # @raise [WorkerRegistrationError] when a worker_activities entry does not resolve
        #   to a Temporalio::Activity::Definition subclass
        def resolve(configuration)
          workflows = []
          activities = custom_activities(configuration)

          if configuration.worker_activejob_workloads
            workflows += [
              Workflows::AjWorkflow,
              Workflows::DeadLetterWorkflow
            ]
            activities += [
              Activities::RateLimitActivity,
              Activities::DependencyStatusActivity,
              Activities::AjRunnerActivity
            ]
          end

          Result.new(workflows: workflows, activities: activities)
        end

        private

        def custom_activities(configuration)
          Array(configuration.worker_activities).map { |entry| resolve_activity(entry) }
        end

        def resolve_activity(entry)
          activity = entry.is_a?(String) ? constantize_activity(entry) : entry
          return activity if activity.is_a?(Class) && activity < Temporalio::Activity::Definition

          raise WorkerRegistrationError,
                "worker_activities entry #{entry.inspect} is not a Temporalio::Activity::Definition subclass"
        end

        def constantize_activity(name)
          name.constantize
        rescue NameError
          raise WorkerRegistrationError, "worker_activities entry #{name.inspect} does not resolve to a class"
        end
      end
    end
  end
end
