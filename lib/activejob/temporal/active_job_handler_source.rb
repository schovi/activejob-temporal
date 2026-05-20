# frozen_string_literal: true

module ActiveJob
  module Temporal
    class ActiveJobHandlerSource
      def self.match?(handler, method_name)
        new(handler, method_name).match?
      end

      def initialize(handler, method_name)
        @handler = handler
        @method_name = method_name
      end

      def match?
        return false unless handler.respond_to?(:source_location)

        source_file, source_line = handler.source_location
        return false unless source_file && source_line

        method_file, = active_job_method_source_location
        return false unless method_file
        return false unless same_file?(source_file, method_file)

        source_method_name(source_file, source_line) == method_name.to_s
      rescue StandardError
        false
      end

      private

      attr_reader :handler, :method_name

      def active_job_method_source_location
        return nil unless defined?(ActiveJob::Exceptions::ClassMethods)

        ActiveJob::Exceptions::ClassMethods.instance_method(method_name).source_location
      rescue NameError
        nil
      end

      def same_file?(left, right)
        File.expand_path(left) == File.expand_path(right)
      end

      def source_method_name(source_file, source_line)
        return nil unless File.file?(source_file)

        lines = File.readlines(source_file)
        (source_line.to_i - 1).downto(0) do |line_index|
          line = lines[line_index]
          next unless line

          match = line.match(/^\s*def\s+([a-zA-Z_]\w*[!?=]?)/)
          return match[1] if match
        end

        nil
      end
    end
  end
end
