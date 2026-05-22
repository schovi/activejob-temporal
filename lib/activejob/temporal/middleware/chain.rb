# frozen_string_literal: true

module ActiveJob
  module Temporal
    module Middleware
      # Ordered middleware pipeline for ActiveJob execution inside Temporal activities.
      class Chain
        include Enumerable

        TERMINAL_CALL_CHAIN = ->(_job, terminal) { terminal.call }.freeze

        def initialize(entries = [])
          @entries = []
          @compiled_call_chain = TERMINAL_CALL_CHAIN
          entries.each { |entry| add(entry) }
        end

        def add(middleware, *args, **kwargs, &block)
          callable = build_callable(middleware, args, kwargs, block)
          @entries << callable
          @compiled_call_chain = compile_call_chain

          callable
        end

        def call(job, &terminal)
          raise ArgumentError, "middleware chain requires a block" unless terminal

          @compiled_call_chain.call(job, terminal)
        end

        def each(&block)
          return enum_for(:each) unless block

          @entries.each(&block)
        end

        private

        def compile_call_chain
          @entries.reverse_each.reduce(TERMINAL_CALL_CHAIN) do |next_middleware, middleware|
            lambda do |job, terminal|
              middleware.call(job) { next_middleware.call(job, terminal) }
            end
          end
        end

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
