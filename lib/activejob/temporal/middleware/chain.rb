# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Middleware
      # Ordered middleware pipeline for ActiveJob execution inside Temporal activities.
      class Chain
        include Enumerable

        def initialize(entries = [])
          @entries = []
          entries.each { |entry| add(entry) }
        end

        def add(middleware, *args, **kwargs, &block)
          callable = build_callable(middleware, args, kwargs, block)
          @entries << callable

          callable
        end

        def call(job, &terminal)
          raise ArgumentError, "middleware chain requires a block" unless terminal

          @entries.reverse_each.reduce(terminal) do |next_middleware, middleware|
            proc { middleware.call(job, &next_middleware) }
          end.call
        end

        def each(&block)
          return enum_for(:each) unless block

          @entries.each(&block)
        end

        private

        def build_callable(middleware, args, kwargs, block)
          callable = if middleware.is_a?(Class)
                       middleware.new(*args, **kwargs, &block)
                     elsif args.empty? && kwargs.empty? && block.nil?
                       middleware
                     else
                       raise ArgumentError, "middleware arguments require a middleware class"
                     end

          return callable if callable.respond_to?(:call)

          raise ArgumentError, "middleware must respond to #call"
        end
      end
    end
  end
end
