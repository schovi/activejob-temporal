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
    it "rejects middleware that cannot be called" do
      middleware_class = Class.new

      expect { chain.add(middleware_class) }.to raise_error(ArgumentError, /respond to #call/)
    end

    it "rejects constructor arguments for callable instances" do
      middleware = ->(_job, &block) { block.call }

      expect { chain.add(middleware, :argument) }.to raise_error(ArgumentError, /arguments require/)
    end
  end
end
