# frozen_string_literal: true

require "active_job"

module ActiveJob
  module Temporal
    module Schedulable
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def temporal_schedule(options = nil, **kwargs)
          return @temporal_schedule if options.nil? && kwargs.empty?

          schedule_options = normalize_schedule_options(options, kwargs)
          @temporal_schedule = ActiveJob::Temporal::Schedule.new(self, schedule_options)
        end

        def create_temporal_schedule(options = nil, **kwargs)
          if options || kwargs.any?
            schedule_options = merged_schedule_options(normalize_schedule_options(options, kwargs))
            return ActiveJob::Temporal::Schedule.new(self, schedule_options).create
          end

          raise ArgumentError, "No temporal_schedule defined for #{name}" unless temporal_schedule

          temporal_schedule.create
        end

        def temporal_schedule_handle(id: nil, client: ActiveJob::Temporal.client)
          client.schedule_handle(id || temporal_schedule&.id || "ajsch:#{name}")
        end

        private

        def normalize_schedule_options(options, kwargs)
          case options
          when nil
            kwargs
          when Hash
            options.merge(kwargs)
          else
            raise ArgumentError, "temporal_schedule options must be a Hash"
          end
        end

        def merged_schedule_options(overrides)
          return overrides unless temporal_schedule

          temporal_schedule.options.merge(overrides)
        end
      end
    end
  end
end

ActiveJob::Base.include(ActiveJob::Temporal::Schedulable) if defined?(ActiveJob::Base)
