# frozen_string_literal: true

# rubocop:disable Lint/MissingSuper, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Style/CaseEquality

module MinitestExpectations
  UNDEFINED = Object.new.freeze

  class Matcher
    def assert(test, actual)
      test.assert matches?(actual), failure_message(actual)
    end

    def refute(test, actual)
      test.refute matches?(actual), negative_failure_message(actual)
    end

    def failure_message(actual)
      "Expected #{actual.inspect} to match #{inspect}"
    end

    def negative_failure_message(actual)
      "Expected #{actual.inspect} not to match #{inspect}"
    end
  end

  class EqMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual)
      values_match?(@expected, actual)
    end

    def assert(test, actual)
      return test.assert_nil(actual) if @expected.nil?

      if contains_matcher?(@expected)
        super
      else
        test.assert_equal @expected, actual
      end
    end

    private

    def contains_matcher?(value)
      case value
      when Matcher
        true
      when Array
        value.any? { |item| contains_matcher?(item) }
      when Hash
        value.any? { |key, item| contains_matcher?(key) || contains_matcher?(item) }
      else
        false
      end
    end
  end

  class EqualMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual)
      actual.equal?(@expected)
    end
  end

  class BeMatcher < Matcher
    def initialize(expected = UNDEFINED)
      @expected = expected
    end

    def matches?(actual)
      return true if @expected.equal?(UNDEFINED)

      actual.equal?(@expected)
    end

    def ==(other)
      ComparisonMatcher.new(:==, other)
    end

    def !=(other)
      ComparisonMatcher.new(:!=, other)
    end

    def <(other)
      ComparisonMatcher.new(:<, other)
    end

    def <=(other)
      ComparisonMatcher.new(:<=, other)
    end

    def >(other)
      ComparisonMatcher.new(:>, other)
    end

    def >=(other)
      ComparisonMatcher.new(:>=, other)
    end
  end

  class ComparisonMatcher < Matcher
    def initialize(operator, expected)
      @operator = operator
      @expected = expected
    end

    def matches?(actual)
      actual.public_send(@operator, @expected)
    end
  end

  class NilMatcher < Matcher
    def matches?(actual)
      actual.nil?
    end
  end

  class EmptyMatcher < Matcher
    def matches?(actual)
      actual.empty?
    end
  end

  class KindOfMatcher < Matcher
    def initialize(expected_class)
      @expected_class = expected_class
    end

    def matches?(actual)
      actual.is_a?(@expected_class)
    end
  end

  class InstanceOfMatcher < Matcher
    def initialize(expected_class)
      @expected_class = expected_class
    end

    def matches?(actual)
      actual.instance_of?(@expected_class)
    end
  end

  class PredicateMatcher < Matcher
    def initialize(method_name)
      @method_name = method_name
    end

    def matches?(actual)
      actual.public_send(@method_name)
    end
  end

  class SatisfyMatcher < Matcher
    def initialize(block)
      @block = block
    end

    def matches?(actual)
      @block.call(actual)
    end

    def with_block(block)
      @block = block
      self
    end
  end

  class RespondToMatcher < Matcher
    def initialize(method_name)
      @method_name = method_name
    end

    def matches?(actual)
      actual.respond_to?(@method_name)
    end
  end

  class MatchMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual)
      @expected === actual
    end
  end

  class IncludeMatcher < Matcher
    def initialize(*expected)
      @expected = expected
    end

    def matches?(actual)
      if actual.is_a?(Hash) && @expected.one? && @expected.first.is_a?(Hash)
        return hash_includes?(actual, @expected.first)
      end

      if actual.respond_to?(:any?) && !actual.is_a?(String)
        return @expected.all? do |expected|
          actual.any? { |actual_item| values_match?(expected, actual_item) }
        end
      end

      @expected.all? { |expected| actual.include?(expected) }
    end
  end

  class HaveKeyMatcher < Matcher
    def initialize(expected_key)
      @expected_key = expected_key
    end

    def matches?(actual)
      actual.key?(@expected_key)
    end
  end

  class HashIncludingMatcher < Matcher
    def initialize(*expected_keys, **expected_values)
      @expected_keys = expected_keys
      @expected_values = expected_values
    end

    def matches?(actual)
      return false unless actual.is_a?(Hash)

      @expected_keys.all? { |key| actual.key?(key) } && hash_includes?(actual, @expected_values)
    end
  end

  class HashExcludingMatcher < Matcher
    def initialize(*excluded_keys)
      @excluded_keys = excluded_keys
    end

    def matches?(actual)
      actual.is_a?(Hash) && @excluded_keys.none? { |key| actual.key?(key) }
    end
  end

  class ContainExactlyMatcher < Matcher
    def initialize(*expected)
      @expected = expected
    end

    def matches?(actual)
      match_unordered?(@expected, actual.to_a)
    end
  end

  class AllMatcher < Matcher
    def initialize(expected_matcher)
      @expected_matcher = expected_matcher
    end

    def matches?(actual)
      actual.all? { |item| values_match?(@expected_matcher, item) }
    end
  end

  class StartWithMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual)
      actual.start_with?(@expected)
    end
  end

  class EndWithMatcher < Matcher
    def initialize(expected)
      @expected = expected
    end

    def matches?(actual)
      actual.end_with?(@expected)
    end
  end

  class AnythingMatcher < Matcher
    def matches?(_actual)
      true
    end
  end

  class StringMatchingMatcher < Matcher
    def initialize(pattern)
      @pattern = pattern
    end

    def matches?(actual)
      actual.is_a?(String) && @pattern.match?(actual)
    end
  end

  class ExistMatcher < Matcher
    def initialize(*arguments)
      @arguments = arguments
    end

    def matches?(actual)
      if actual.respond_to?(:exist?)
        actual.exist?(*@arguments)
      else
        actual.exist(*@arguments)
      end
    end
  end

  class BeWithinMatcher
    def initialize(delta)
      @delta = delta
    end

    def of(expected)
      WithinMatcher.new(expected, @delta)
    end
  end

  class BeBetweenMatcher < Matcher
    def initialize(minimum, maximum)
      @minimum = minimum
      @maximum = maximum
    end

    def matches?(actual)
      actual.between?(@minimum, @maximum)
    end

    def inclusive
      self
    end
  end

  class WithinMatcher < Matcher
    def initialize(expected, delta)
      @expected = expected
      @delta = delta
    end

    def matches?(actual)
      (actual - @expected).abs <= @delta
    end
  end

  class RaiseErrorMatcher
    def initialize(expected_error = Exception, expected_message = nil)
      @expected_error = expected_error
      @expected_message = expected_message
    end

    def assert(test, block, &verifier)
      error = captured_error(block)

      test.assert error, "Expected block to raise #{@expected_error.inspect}"
      assert_error_matches(test, error)
      verifier&.call(error)
    end

    def refute(test, block)
      error = captured_error(block)

      return unless error

      test.fail "Expected block not to raise, but raised #{error.class}: #{error.message}"
    end

    private

    def captured_error(block)
      block.call
      nil
    rescue Exception => e # rubocop:disable Lint/RescueException
      e
    end

    def assert_error_matches(test, error)
      if @expected_error.is_a?(Exception)
        test.assert_same @expected_error, error
      elsif @expected_error
        test.assert_kind_of @expected_error, error
      end

      case @expected_message
      when Regexp
        test.assert_match @expected_message, error.message
      when String
        test.assert_equal @expected_message, error.message
      when nil
        nil
      else
        test.assert values_match?(@expected_message, error.message)
      end
    end
  end

  class OutputMatcher
    def initialize(expected)
      @expected = expected
      @stream = :stdout
    end

    def to_stdout
      @stream = :stdout
      self
    end

    def to_stderr
      @stream = :stderr
      self
    end

    def assert(test, block)
      stdout, stderr = test.capture_io { block.call }
      output = @stream == :stderr ? stderr : stdout

      if @expected.is_a?(Regexp)
        test.assert_match @expected, output
      else
        test.assert_equal @expected, output
      end
    end
  end

  Call = Struct.new(:method_name, :arguments, :keywords, keyword_init: true)

  class MockProxy
    attr_reader :calls

    def initialize(object)
      @object = object
      @calls = []
      @stubs = Hash.new { |hash, key| hash[key] = [] }
      @expectations = []
      @originals = {}
      @stub_order = 0
    end

    def add_stub(stub)
      install_method(stub.method_name)
      @stub_order += 1
      stub.order = @stub_order
      @stubs[stub.method_name] << stub
      stub
    end

    def add_expectation(stub)
      @expectations << stub
      add_stub(stub)
    end

    def calls_for(method_name)
      calls.select { |call| call.method_name == method_name }
    end

    def verify(test)
      @expectations.each { |expectation| expectation.verify(test, calls_for(expectation.method_name)) }
    end

    def restore
      @originals.each do |method_name, original|
        singleton_class = @object.singleton_class
        if singleton_class.method_defined?(method_name) || singleton_class.private_method_defined?(method_name)
          singleton_class.__send__(:remove_method, method_name)
        end

        next unless original[:had_singleton_method]

        singleton_class.define_method(method_name, original[:unbound_method])
        singleton_class.__send__(original[:visibility], method_name)
      end
    end

    private

    def install_method(method_name)
      return if @originals.key?(method_name)

      singleton_class = @object.singleton_class
      visibility = method_visibility(singleton_class, method_name)
      @originals[method_name] = {
        had_singleton_method: !visibility.nil?,
        unbound_method: visibility ? singleton_class.instance_method(method_name) : nil,
        visibility: visibility || :public
      }

      proxy = self
      singleton_class.define_method(method_name) do |*arguments, **keywords, &block|
        proxy.invoke(method_name, *arguments, **keywords, &block)
      end
    end

    def method_visibility(singleton_class, method_name)
      return :public if singleton_class.public_method_defined?(method_name)
      return :protected if singleton_class.protected_method_defined?(method_name)
      return :private if singleton_class.private_method_defined?(method_name)

      nil
    end

    public

    def invoke(method_name, *arguments, **keywords, &)
      call = Call.new(method_name: method_name, arguments: arguments, keywords: keywords)
      calls << call

      stub = matching_stub(method_name, call)
      return stub.invoke(original_callable(method_name), *arguments, **keywords, &) if stub

      original_callable(method_name).call(*arguments, **keywords, &)
    end

    private

    def matching_stub(method_name, call)
      @stubs[method_name].rfind { |stub| stub.matches_call?(call) }
    end

    def original_callable(method_name)
      original = @originals.fetch(method_name)
      return proc {} unless original[:unbound_method]

      original[:unbound_method].bind(@object)
    end
  end

  class StubDefinition
    attr_accessor :order
    attr_reader :method_name

    def initialize(method_name)
      @method_name = method_name
      @expected_arguments = nil
      @expected_keywords = nil
      @behavior = :return
      @return_values = [nil]
      @return_index = 0
      @minimum_calls = nil
      @maximum_calls = nil
    end

    def with(*arguments, **keywords)
      @expected_arguments = arguments
      @expected_keywords = keywords
      self
    end

    def and_return(*values)
      @behavior = :return
      @return_values = values.empty? ? [nil] : values
      self
    end

    def and_raise(*arguments)
      @behavior = :raise
      @raise_arguments = arguments
      self
    end

    def and_yield(*arguments)
      @behavior = :yield
      @yield_arguments = arguments
      self
    end

    def and_call_original
      @behavior = :call_original
      self
    end

    def and_wrap_original(&block)
      @behavior = :wrap_original
      @implementation = block
      self
    end

    def implement(&block)
      @behavior = :implementation
      @implementation = block
      self
    end

    def attach_block(&block)
      if @behavior == :wrap_original
        @implementation = block
      elsif @behavior == :return && @return_values == [nil]
        implement(&block)
      end

      self
    end

    def once
      exactly(1)
    end

    def twice
      exactly(2)
    end

    def exactly(count)
      @minimum_calls = count
      @maximum_calls = count
      self
    end

    def times
      self
    end

    def matches_call?(call)
      return true unless @expected_arguments

      arguments_and_keywords_match?(@expected_arguments, @expected_keywords, call.arguments, call.keywords)
    end

    def specificity
      @expected_arguments ? 1 : 0
    end

    def invoke(original, *, **keywords, &block)
      case @behavior
      when :return
        next_return_value
      when :raise
        raise_error_from_arguments
      when :yield
        block&.call(*@yield_arguments)
      when :call_original
        original.call(*, **keywords, &block)
      when :wrap_original
        @implementation.call(original, *, **keywords, &block)
      when :implementation
        @implementation.call(*, **keywords, &block)
      end
    end

    def verify(test, calls)
      matching_calls = calls.select { |call| matches_call?(call) }
      minimum_calls = @minimum_calls || 1
      maximum_calls = @maximum_calls || 1

      test.assert_operator matching_calls.size, :>=, minimum_calls
      test.assert_operator matching_calls.size, :<=, maximum_calls
    end

    private

    def next_return_value
      value = @return_values[@return_index] || @return_values.last
      @return_index += 1 if @return_index < @return_values.length - 1
      value
    end

    def raise_error_from_arguments
      first_argument, *remaining_arguments = @raise_arguments

      raise first_argument if first_argument.is_a?(Exception)
      raise first_argument, *remaining_arguments if first_argument.is_a?(Class)

      raise first_argument
    end
  end

  class ReceiveMatcher < StubDefinition
  end

  class ReceiveMessagesMatcher
    def initialize(messages)
      @messages = messages
    end

    def install(test, object, expectation: false)
      @messages.each do |method_name, value|
        ReceiveMatcher.new(method_name).and_return(value).install(test, object, expectation: expectation)
      end
    end
  end

  class StubDefinition
    def install(test, object, expectation: false)
      proxy = test.mock_proxy_for(object)
      expectation ? proxy.add_expectation(self) : proxy.add_stub(self)
    end
  end

  class HaveReceivedMatcher
    def initialize(method_name)
      @method_name = method_name
      @expected_arguments = nil
      @expected_keywords = nil
      @minimum_calls = 1
      @maximum_calls = nil
      @verifier = nil
    end

    def with(*arguments, **keywords)
      @expected_arguments = arguments
      @expected_keywords = keywords
      self
    end

    def once
      exactly(1)
    end

    def twice
      exactly(2)
    end

    def exactly(count)
      @minimum_calls = count
      @maximum_calls = count
      self
    end

    def times
      self
    end

    def with_block(block)
      @verifier = block
      self
    end

    def assert(test, object)
      calls = matching_calls(test, object)

      test.assert_operator calls.size, :>=, @minimum_calls
      test.assert_operator calls.size, :<=, @maximum_calls if @maximum_calls
      assert_verifier_matches(test, calls) if @verifier
    end

    def refute(test, object)
      test.assert_empty matching_calls(test, object)
    end

    private

    def matching_calls(test, object)
      proxy = test.mock_proxy_for(object)
      calls = proxy.calls_for(@method_name)
      calls += object.__calls.select { |call| call.method_name == @method_name } if object.respond_to?(:__calls)
      return calls unless @expected_arguments

      calls.select do |call|
        arguments_and_keywords_match?(@expected_arguments, @expected_keywords, call.arguments, call.keywords)
      end
    end

    def assert_verifier_matches(test, calls)
      last_error = nil

      matched = calls.any? do |call|
        call_verifier(call)
        true
      rescue Minitest::Assertion => e
        last_error = e
        false
      end
      return if matched

      test.fail "Expected #{@method_name} to have a received call satisfying the block: #{last_error&.message}"
    end

    def call_verifier(call)
      if call.keywords.empty?
        @verifier.call(*call.arguments)
      else
        @verifier.call(*call.arguments, **call.keywords)
      end
    end
  end

  class AllowanceTarget
    def initialize(test, object)
      @test = test
      @object = object
    end

    def to(matcher, &block)
      matcher.attach_block(&block) if block && matcher.respond_to?(:attach_block)
      matcher.install(@test, @object, expectation: false)
      matcher
    end
  end

  class AnyInstanceAllowanceTarget
    def initialize(test, expected_class)
      @test = test
      @expected_class = expected_class
    end

    def to(matcher, &block)
      matcher.attach_block(&block) if block && matcher.respond_to?(:attach_block)
      @test.stub_any_instance_method(@expected_class, matcher)
      matcher
    end
  end

  class ValueExpectation
    def initialize(test, actual)
      @test = test
      @actual = actual
    end

    def to(matcher, _message = nil, &block)
      if matcher.is_a?(ReceiveMatcher) || matcher.is_a?(ReceiveMessagesMatcher)
        matcher.attach_block(&block) if block && matcher.respond_to?(:attach_block)
        matcher.install(@test, @actual, expectation: true)
      elsif matcher.is_a?(HaveReceivedMatcher)
        matcher.with_block(block) if block
        matcher.assert(@test, @actual)
      else
        matcher.with_block(block) if block && matcher.respond_to?(:with_block)
        matcher.assert(@test, @actual, &block)
      end

      matcher
    end

    def not_to(matcher, _message = nil, &)
      if matcher.is_a?(ReceiveMatcher)
        matcher.exactly(0).install(@test, @actual, expectation: true)
      elsif matcher.is_a?(HaveReceivedMatcher)
        matcher.refute(@test, @actual)
      else
        matcher.refute(@test, @actual, &)
      end

      matcher
    end
  end

  class BlockExpectation
    def initialize(test, block)
      @test = test
      @block = block
    end

    def to(matcher, &)
      matcher.assert(@test, @block, &)
      matcher
    end

    def not_to(matcher)
      matcher.refute(@test, @block)
      matcher
    end
  end

  class TestDouble
    attr_reader :__calls

    def initialize(name = nil, stubs = {})
      @__name = name
      @__calls = []
      @__stubs = {}
      stubs.each { |method_name, value| __set_stub(method_name, value) }
    end

    def __set_stub(method_name, value)
      @__stubs[method_name.to_sym] = value
      define_singleton_method(method_name) do |*arguments, **keywords, &block|
        __record_call(method_name, *arguments, **keywords)
        stub_value = @__stubs.fetch(method_name.to_sym)
        stub_value.respond_to?(:call) ? stub_value.call(*arguments, **keywords, &block) : stub_value
      end
    end

    def __record_call(method_name, *arguments, **keywords)
      __calls << Call.new(method_name: method_name.to_sym, arguments: arguments, keywords: keywords)
    end

    def method_missing(method_name, *, **keywords, &)
      __record_call(method_name, *, **keywords)
      return super unless @__stubs.key?(method_name)

      stub_value = @__stubs.fetch(method_name)
      stub_value.respond_to?(:call) ? stub_value.call(*, **keywords, &) : stub_value
    end

    def respond_to_missing?(method_name, _include_private = false)
      @__stubs.key?(method_name) || super
    end

    def inspect
      "#<TestDouble #{@__name}>"
    end
  end

  module Helpers
    def expect(actual = UNDEFINED, &block)
      return BlockExpectation.new(self, block) if block

      ValueExpectation.new(self, actual)
    end

    def allow(object)
      AllowanceTarget.new(self, object)
    end

    def allow_any_instance_of(expected_class)
      AnyInstanceAllowanceTarget.new(self, expected_class)
    end

    def double(name = nil, stubs = {})
      TestDouble.new(name, stubs)
    end

    def instance_double(expected_class, stubs = {})
      TestDouble.new(expected_class, verified_instance_stubs(expected_class).merge(stubs))
    end

    def instance_spy(expected_class, stubs = {})
      instance_double(expected_class, stubs)
    end

    def class_double(expected_class, stubs = {})
      TestDouble.new(expected_class, stubs)
    end

    def receive(method_name, &block)
      ReceiveMatcher.new(method_name).tap do |matcher|
        matcher.attach_block(&block) if block
      end
    end

    def receive_messages(messages)
      ReceiveMessagesMatcher.new(messages)
    end

    def have_received(method_name, &block)
      HaveReceivedMatcher.new(method_name).tap do |matcher|
        matcher.with_block(block) if block
      end
    end

    def eq(expected)
      EqMatcher.new(expected)
    end

    def equal(expected)
      EqualMatcher.new(expected)
    end

    def be(expected = UNDEFINED)
      BeMatcher.new(expected)
    end

    def be_nil
      NilMatcher.new
    end

    def be_empty
      EmptyMatcher.new
    end

    def be_a(expected_class)
      KindOfMatcher.new(expected_class)
    end

    def be_an(expected_class)
      KindOfMatcher.new(expected_class)
    end

    def be_between(minimum, maximum)
      BeBetweenMatcher.new(minimum, maximum)
    end

    def instance_of(expected_class)
      InstanceOfMatcher.new(expected_class)
    end

    def an_instance_of(expected_class)
      InstanceOfMatcher.new(expected_class)
    end

    def a_kind_of(expected_class)
      KindOfMatcher.new(expected_class)
    end

    def kind_of(expected_class)
      KindOfMatcher.new(expected_class)
    end

    def respond_to(method_name)
      RespondToMatcher.new(method_name)
    end

    def match(expected)
      MatchMatcher.new(expected)
    end

    def include(*expected)
      IncludeMatcher.new(*expected)
    end

    def have_key(expected_key)
      HaveKeyMatcher.new(expected_key)
    end

    def hash_including(*expected_keys, **expected_values)
      HashIncludingMatcher.new(*expected_keys, **expected_values)
    end

    def hash_excluding(*excluded_keys)
      HashExcludingMatcher.new(*excluded_keys)
    end

    def contain_exactly(*expected)
      ContainExactlyMatcher.new(*expected)
    end

    def all(expected_matcher)
      AllMatcher.new(expected_matcher)
    end

    def start_with(expected)
      StartWithMatcher.new(expected)
    end

    def end_with(expected)
      EndWithMatcher.new(expected)
    end

    def anything
      AnythingMatcher.new
    end

    def a_string_matching(pattern)
      StringMatchingMatcher.new(pattern)
    end

    def satisfy(&block)
      SatisfyMatcher.new(block)
    end

    def exist(*)
      ExistMatcher.new(*)
    end

    def be_within(delta)
      BeWithinMatcher.new(delta)
    end

    def raise_error(expected_error = Exception, expected_message = nil)
      RaiseErrorMatcher.new(expected_error, expected_message)
    end

    def output(expected)
      OutputMatcher.new(expected)
    end

    def mock_proxy_for(object)
      @mock_proxies ||= {}
      @mock_proxies[object.__id__] ||= MockProxy.new(object)
    end

    def verify_mock_expectations
      @mock_proxies&.each_value { |proxy| proxy.verify(self) }
    end

    def restore_mock_proxies
      @mock_proxies&.each_value(&:restore)
      @mock_proxies = {}
    end

    def stub_any_instance_method(expected_class, matcher)
      @any_instance_stubs ||= []
      method_name = matcher.method_name
      visibility = any_instance_method_visibility(expected_class, method_name)
      original_method = visibility ? expected_class.instance_method(method_name) : nil
      @any_instance_stubs << [expected_class, method_name, visibility, original_method]

      expected_class.define_method(method_name) do |*arguments, **keywords, &block|
        call = Call.new(method_name: method_name, arguments: arguments, keywords: keywords)
        matcher.invoke(original_method&.bind(self) || proc {}, *call.arguments, **call.keywords, &block)
      end
    end

    def restore_any_instance_stubs
      Array(@any_instance_stubs).reverse_each do |expected_class, method_name, visibility, original_method|
        expected_class.__send__(:remove_method, method_name) if expected_class.method_defined?(method_name)
        next unless visibility

        expected_class.define_method(method_name, original_method)
        expected_class.__send__(visibility, method_name)
      end
      @any_instance_stubs = []
    end

    def method_missing(method_name, ...)
      return PredicateMatcher.new(:"#{method_name.to_s.delete_prefix('be_')}?") if method_name.to_s.start_with?("be_")

      super
    end

    def respond_to_missing?(method_name, include_private = false)
      method_name.to_s.start_with?("be_") || super
    end

    private

    def verified_instance_stubs(expected_class)
      return {} unless expected_class.is_a?(Module)

      unsafe_methods = Object.public_instance_methods + BasicObject.instance_methods
      expected_class.public_instance_methods.each_with_object({}) do |method_name, stubs|
        next if unsafe_methods.include?(method_name)

        stubs[method_name] = nil
      end
    end

    def any_instance_method_visibility(expected_class, method_name)
      return :public if expected_class.public_method_defined?(method_name)
      return :protected if expected_class.protected_method_defined?(method_name)
      return :private if expected_class.private_method_defined?(method_name)

      nil
    end
  end

  module SpecDsl
    def context(...)
      describe(...)
    end

    def subject(name = nil, &)
      return super(&) unless name

      let(name, &)
      let(:subject) { public_send(name) }
    end
  end

  module KernelDsl
    def context(...)
      describe(...)
    end
  end

  module_function

  def values_match?(expected, actual)
    case expected
    when Matcher
      expected.matches?(actual)
    when Array
      actual.is_a?(Array) && expected.length == actual.length &&
        expected.zip(actual).all? { |expected_item, actual_item| values_match?(expected_item, actual_item) }
    when Hash
      actual.is_a?(Hash) && expected.length == actual.length &&
        expected.all? { |key, value| actual.key?(key) && values_match?(value, actual[key]) }
    when Regexp
      expected.match?(actual)
    else
      expected == actual
    end
  end

  def hash_includes?(actual, expected)
    expected.all? do |key, value|
      actual.key?(key) && values_match?(value, actual[key])
    end
  end

  def match_unordered?(expected, actual)
    return false unless expected.length == actual.length

    remaining = actual.dup
    expected.all? do |expected_item|
      index = remaining.find_index { |actual_item| values_match?(expected_item, actual_item) }
      next false unless index

      remaining.delete_at(index)
      true
    end
  end

  def arguments_match?(expected_arguments, actual_arguments)
    return false unless expected_arguments.length == actual_arguments.length

    expected_arguments.zip(actual_arguments).all? do |expected_argument, actual_argument|
      values_match?(expected_argument, actual_argument)
    end
  end

  def keywords_match?(expected_keywords, actual_keywords)
    return actual_keywords.empty? if expected_keywords.nil? || expected_keywords.empty?

    return false unless expected_keywords.length == actual_keywords.length

    expected_keywords.all? do |key, value|
      actual_keywords.key?(key) && values_match?(value, actual_keywords[key])
    end
  end

  def arguments_and_keywords_match?(expected_arguments, expected_keywords, actual_arguments, actual_keywords)
    if (expected_keywords.nil? || expected_keywords.empty?) &&
       !actual_keywords.empty? &&
       expected_arguments.length == actual_arguments.length + 1
      expected_trailing_argument = expected_arguments.last
      if expected_trailing_argument.is_a?(Matcher) || expected_trailing_argument.is_a?(Hash)
        return arguments_match?(expected_arguments[0...-1], actual_arguments) &&
               values_match?(expected_trailing_argument, actual_keywords)
      end
    end

    if expected_keywords && !expected_keywords.empty? &&
       actual_keywords.empty? &&
       actual_arguments.last.is_a?(Hash) &&
       actual_arguments.length == expected_arguments.length + 1
      return arguments_match?(expected_arguments, actual_arguments[0...-1]) &&
             keywords_match?(expected_keywords, actual_arguments.last)
    end

    arguments_match?(expected_arguments, actual_arguments) && keywords_match?(expected_keywords, actual_keywords)
  end
end

module MinitestExpectations
  class Matcher
    include MinitestExpectations
  end

  class StubDefinition
    include MinitestExpectations
  end

  class HaveReceivedMatcher
    include MinitestExpectations
  end
end

Minitest::Spec.include(MinitestExpectations::Helpers)
Minitest::Spec.singleton_class.prepend(MinitestExpectations::SpecDsl)
Kernel.prepend(MinitestExpectations::KernelDsl)
# rubocop:enable Lint/MissingSuper, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Style/CaseEquality
