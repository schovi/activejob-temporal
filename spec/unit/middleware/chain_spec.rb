# frozen_string_literal: true

require "spec_helper"

describe ActiveJob::Temporal::Middleware::Chain do
  let(:chain) { described_class.new }

  let(:job) { Object.new }

  describe "#call" do
    it "calls the terminal block when no middleware is registered" do
      assert_equal :performed, chain.call(job) { :performed }
    end

    it "preserves registration order" do
      events = []
      middleware_class = Class.new do
        def initialize(name, events)
          @name = name
          @events = events
        end

        def call(_job)
          @events << "before #{@name}"
          result = yield
          @events << "after #{@name}"
          result
        end
      end

      chain.add(middleware_class, "first", events)
      chain.add(middleware_class, "second", events)

      result = chain.call(job) do
        events << "perform"
        :performed
      end

      assert_equal :performed, result
      assert_equal(
        [
          "before first",
          "before second",
          "perform",
          "after second",
          "after first"
        ],
        events
      )
    end

    it "supports callable middleware instances" do
      events = []
      middleware = lambda do |received_job, &block|
        events << received_job
        block.call
      end

      chain.add(middleware)

      assert_equal :performed, chain.call(job) { :performed }
      assert_equal [job], events
    end

    it "does not rebuild the middleware stack for each call" do
      middleware = ->(_received_job, &block) { block.call }
      chain.add(middleware)
      entries = Object.new
      def entries.reverse_each
        raise "middleware stack was rebuilt"
      end
      chain.instance_variable_set(:@entries, entries)

      assert_equal :performed, chain.call(job) { :performed }
    end

    it "propagates middleware exceptions" do
      error = RuntimeError.new("middleware failed")
      middleware_class = Class.new do
        def initialize(error)
          @error = error
        end

        def call(_job)
          raise @error
        end
      end

      chain.add(middleware_class, error)

      raised_error = assert_raises(RuntimeError) { chain.call(job) { :performed } }
      assert_same error, raised_error
    end

    it "requires a terminal block" do
      error = assert_raises(ArgumentError) { chain.call(job) }
      assert_match(/requires a block/, error.message)
    end
  end

  describe "#add" do
    it "replaces an equivalent middleware registration" do
      middleware_class = Class.new do
        def initialize(events)
          @events = events
        end

        def call(_job)
          @events << :called
          yield
        end
      end
      events = []

      chain.add(middleware_class, events)
      chain.add(middleware_class, events)
      chain.call(job) { :performed }

      assert_equal [:called], events
    end

    it "keeps equivalent registrations stable when constructor arguments mutate" do
      middleware_class = Class.new do
        def initialize(events)
          @events = events
        end

        def call(_job)
          @events << :called
          yield
        end
      end
      events = []

      chain.add(middleware_class, events)
      chain.call(job) { :performed }
      chain.add(middleware_class, events)
      chain.call(job) { :performed }

      assert_equal %i[called called], events
    end

    it "keeps scalar argument keys stable when original strings mutate" do
      middleware_class = Class.new do
        def initialize(name, events)
          @name = name
          @events = events
        end

        def call(_job)
          @events << @name
          yield
        end
      end
      name = +"initial"
      events = []

      chain.add(middleware_class, name, events)
      name.replace("changed")
      chain.add(middleware_class, "initial", events)
      chain.call(job) { :performed }

      assert_equal ["initial"], events
    end

    it "allows repeated middleware classes with different arguments" do
      middleware_class = Class.new do
        def initialize(name, events)
          @name = name
          @events = events
        end

        def call(_job)
          @events << @name
          yield
        end
      end
      events = []

      chain.add(middleware_class, :first, events)
      chain.add(middleware_class, :second, events)
      chain.call(job) { :performed }

      assert_equal %i[first second], events
    end

    it "replaces reloaded middleware classes with the same name" do
      first_class = Class.new do
        def self.name
          "ReloadableMiddleware"
        end

        def call(_job)
          :first
        end
      end
      second_class = Class.new do
        def self.name
          "ReloadableMiddleware"
        end

        def call(_job)
          yield
        end
      end

      chain.add(first_class)
      chain.add(second_class)

      assert_equal :performed, chain.call(job) { :performed }
    end

    it "replaces reloaded callable middleware from the same source" do
      events = []

      chain.add(build_reloadable_callable(events))
      chain.add(build_reloadable_callable(events))
      chain.call(job) { :performed }

      assert_equal [:called], events
    end

    it "rejects middleware that cannot be called" do
      middleware_class = Class.new

      error = assert_raises(ArgumentError) { chain.add(middleware_class) }
      assert_match(/respond to #call/, error.message)
    end

    it "rejects constructor arguments for callable instances" do
      middleware = ->(_job, &block) { block.call }

      error = assert_raises(ArgumentError) { chain.add(middleware, :argument) }
      assert_match(/arguments require/, error.message)
    end
  end

  def build_reloadable_callable(events)
    lambda do |_job, &block|
      events << :called
      block.call
    end
  end
end
