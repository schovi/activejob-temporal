# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::Middleware::Chain do
  subject(:chain) { described_class.new }

  let(:job) { instance_double("Job") }

  describe "#call" do
    it "calls the terminal block when no middleware is registered" do
      expect(chain.call(job) { :performed }).to eq(:performed)
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

      expect(result).to eq(:performed)
      expect(events).to eq([
                             "before first",
                             "before second",
                             "perform",
                             "after second",
                             "after first"
                           ])
    end

    it "supports callable middleware instances" do
      events = []
      middleware = lambda do |received_job, &block|
        events << received_job
        block.call
      end

      chain.add(middleware)

      expect(chain.call(job) { :performed }).to eq(:performed)
      expect(events).to eq([job])
    end

    it "does not rebuild the middleware stack for each call" do
      middleware = ->(_received_job, &block) { block.call }
      chain.add(middleware)
      entries = chain.instance_variable_get(:@entries)

      expect(entries).not_to receive(:reverse_each)

      expect(chain.call(job) { :performed }).to eq(:performed)
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

      expect { chain.call(job) { :performed } }.to raise_error(error)
    end

    it "requires a terminal block" do
      expect { chain.call(job) }.to raise_error(ArgumentError, /requires a block/)
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

      expect(events).to eq([:called])
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

      expect(events).to eq(%i[called called])
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

      expect(events).to eq(["initial"])
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

      expect(events).to eq(%i[first second])
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

      expect(chain.call(job) { :performed }).to eq(:performed)
    end

    it "replaces reloaded callable middleware from the same source" do
      events = []

      chain.add(build_reloadable_callable(events))
      chain.add(build_reloadable_callable(events))
      chain.call(job) { :performed }

      expect(events).to eq([:called])
    end

    it "rejects middleware that cannot be called" do
      middleware_class = Class.new

      expect { chain.add(middleware_class) }.to raise_error(ArgumentError, /respond to #call/)
    end

    it "rejects constructor arguments for callable instances" do
      middleware = ->(_job, &block) { block.call }

      expect { chain.add(middleware, :argument) }.to raise_error(ArgumentError, /arguments require/)
    end
  end

  def build_reloadable_callable(events)
    lambda do |_job, &block|
      events << :called
      block.call
    end
  end
end
