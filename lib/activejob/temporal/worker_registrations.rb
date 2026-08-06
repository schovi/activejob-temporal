# frozen_string_literal: true

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
        # @param configuration [ActiveJob::Temporal::Configuration]
        # @return [Result] workflows and activities to pass to Temporalio::Worker
        # @raise [ArgumentError] when the worker would have nothing to register
        # @raise [NameError] when a worker_activities class name does not resolve
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

          if workflows.empty? && activities.empty?
            raise ArgumentError,
                  "worker has nothing to register: worker_activejob_workloads is disabled " \
                  "and worker_activities is empty"
          end

          Result.new(workflows: workflows, activities: activities)
        end

        private

        def custom_activities(configuration)
          Array(configuration.worker_activities).map do |activity|
            activity.is_a?(String) ? activity.constantize : activity
          end
        end
      end
    end
  end
end
