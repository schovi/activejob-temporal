# frozen_string_literal: true

require "stringio"

module MinitestHelpers
  Call = Struct.new(:method_name, :arguments, :keywords, keyword_init: true)

  class CallRecorder
    attr_reader :calls

    def initialize
      @calls = []
    end

    def record(method_name, *arguments, **keywords)
      calls << Call.new(method_name: method_name, arguments: arguments, keywords: keywords)
    end

    def calls_for(method_name)
      calls.select { |call| call.method_name == method_name }
    end
  end

  class AroundExample
    def initialize(action)
      @action = action
    end

    def run
      @action.call
    end
  end

  module SpecAround
    def self.prepended(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def around_hooks
        @around_hooks ||= if superclass.respond_to?(:around_hooks)
                            superclass.around_hooks.dup
                          else
                            []
                          end
      end

      def around(&block)
        around_hooks << block
      end
    end

    def run
      action = proc { super() }

      self.class.around_hooks.reverse_each do |hook|
        previous_action = action
        action = proc { instance_exec(AroundExample.new(previous_action), &hook) }
      end

      action.call
    end
  end

  module Assertions
    def described_class
      current_class = self.class

      while current_class.respond_to?(:desc)
        description = current_class.desc
        return description if description.is_a?(Module)

        current_class = current_class.superclass
      end
    end

    def assert_nothing_raised
      yield
    end

    def assert_hash_includes(expected, actual)
      expected.each do |key, value|
        assert actual.key?(key), "Expected #{actual.inspect} to include key #{key.inspect}"
        assert_equal value, actual[key], "Expected #{key.inspect} to match"
      end
    end

    def assert_unordered_equal(expected, actual)
      assert_equal expected.tally, actual.tally
    end

    def assert_stderr_matches(pattern, &)
      _stdout, stderr = capture_io(&)

      assert_match pattern, stderr
    end

    def call_recorded_method(object, method_name, returns: nil, raises: nil, &implementation)
      recorder = CallRecorder.new
      singleton_class = object.singleton_class
      had_singleton_method = singleton_class.method_defined?(method_name) ||
                             singleton_class.private_method_defined?(method_name)
      original_method = singleton_class.instance_method(method_name) if had_singleton_method
      @stubbed_methods ||= []
      @stubbed_methods << [object, method_name, original_method]

      singleton_class.define_method(method_name) do |*arguments, **keywords, &block|
        recorder.record(method_name, *arguments, **keywords)
        raise raises if raises

        if implementation
          implementation.call(*arguments, **keywords, &block)
        else
          returns
        end
      end

      recorder
    end

    def stub_const(constant_path, value)
      parent, constant_name = constant_parent_and_name(constant_path)
      existed = parent.const_defined?(constant_name, false)
      original_value = parent.const_get(constant_name, false) if existed

      parent.__send__(:remove_const, constant_name) if existed
      parent.const_set(constant_name, value)

      @stubbed_constants ||= []
      @stubbed_constants << [parent, constant_name, existed, original_value]

      value
    end

    def assert_called_with(call_recorder, method_name, *arguments, **keywords)
      matching_call = call_recorder.calls_for(method_name).any? do |call|
        call.arguments == arguments && call.keywords == keywords
      end

      assert matching_call, "Expected #{method_name} to be called with #{arguments.inspect} #{keywords.inspect}"
    end

    def refute_called(call_recorder, method_name)
      assert_empty call_recorder.calls_for(method_name), "Expected #{method_name} not to be called"
    end

    def after_teardown
      verify_mock_expectations if respond_to?(:verify_mock_expectations)
    ensure
      restore_stubbed_constants
      restore_stubbed_methods
      restore_any_instance_stubs if respond_to?(:restore_any_instance_stubs)
      restore_mock_proxies if respond_to?(:restore_mock_proxies)
      super
    end

    private

    def constant_parent_and_name(constant_path)
      names = constant_path.split("::")
      constant_name = names.pop
      parent = names.empty? ? Object : Object.const_get(names.join("::"))

      [parent, constant_name.to_sym]
    end

    def restore_stubbed_constants
      Array(@stubbed_constants).reverse_each do |parent, constant_name, existed, original_value|
        parent.__send__(:remove_const, constant_name) if parent.const_defined?(constant_name, false)
        parent.const_set(constant_name, original_value) if existed
      end
      @stubbed_constants = []
    end

    def restore_stubbed_methods
      Array(@stubbed_methods).reverse_each do |object, method_name, original_method|
        singleton_class = object.singleton_class

        if singleton_class.method_defined?(method_name) || singleton_class.private_method_defined?(method_name)
          singleton_class.__send__(:remove_method, method_name)
        end

        next unless original_method

        singleton_class.define_method(method_name, original_method)
      end
      @stubbed_methods = []
    end
  end
end

Minitest::Spec.prepend(MinitestHelpers::SpecAround)
Minitest::Spec.include(MinitestHelpers::Assertions)
