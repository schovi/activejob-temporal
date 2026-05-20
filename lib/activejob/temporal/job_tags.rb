# frozen_string_literal: true

require "active_job"

module ActiveJob
  module Temporal
    # Captures Temporal search tags passed through ActiveJob's set options.
    module JobTags
      attr_reader :temporal_tags

      def self.normalize(tags)
        return [] if tags.nil?

        raise ArgumentError, "tags must be an Array of Strings or Symbols" unless tags.is_a?(Array)

        tags.map do |tag|
          normalize_tag(tag)
        end.uniq
      end

      def self.normalize_tag(tag)
        return tag if tag.is_a?(String)
        return tag.to_s if tag.is_a?(Symbol)

        raise ArgumentError, "tags must contain only Strings or Symbols"
      end

      def set(options = {})
        enqueue_options = options.dup
        normalized_tags = JobTags.normalize(enqueue_options.delete(:tags)) if enqueue_options.key?(:tags)

        super(enqueue_options).tap do
          @temporal_tags = normalized_tags if options.key?(:tags)
        end
      end
    end
  end
end

ActiveJob::Base.prepend(ActiveJob::Temporal::JobTags) if defined?(ActiveJob::Base)
