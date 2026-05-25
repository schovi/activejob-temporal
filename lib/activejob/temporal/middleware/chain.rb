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
          @entry_indexes_by_key = {}
          @compiled_call_chain = TERMINAL_CALL_CHAIN
          entries.each { |entry| add(entry) }
        end

        def initialize_copy(original)
          super
          @entries = original.instance_variable_get(:@entries).dup
          @entry_indexes_by_key = original.instance_variable_get(:@entry_indexes_by_key).dup
          @compiled_call_chain = compile_call_chain
        end

        def add(middleware, *args, **kwargs, &block)
          key = entry_key(middleware, args, kwargs, block)
          callable = build_callable(middleware, args, kwargs, block)
          upsert_entry(key, callable)
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

        def upsert_entry(key, callable)
          if @entry_indexes_by_key.key?(key)
            @entries[@entry_indexes_by_key.fetch(key)] = callable
          else
            @entry_indexes_by_key[key] = @entries.length
            @entries << callable
          end
        end

        def entry_key(middleware, args, kwargs, block)
          [
            middleware_key(middleware),
            args.map { |argument| argument_key(argument) },
            kwargs.sort_by { |key, _value| key.to_s }.map { |key, value| [key, argument_key(value)] },
            block_key(block)
          ]
        end

        def middleware_key(middleware)
          return [:class, middleware.name] if middleware.is_a?(Class) && middleware.name
          return [:callable_source, middleware.source_location] if middleware.respond_to?(:source_location)

          [:object, middleware.object_id]
        end

        def argument_key(argument)
          case argument
          when NilClass, TrueClass, FalseClass, Numeric, Symbol
            argument
          when String
            argument.dup.freeze
          else
            [:object, argument.object_id]
          end
        end

        def block_key(block)
          block&.source_location || block&.object_id
        end

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
