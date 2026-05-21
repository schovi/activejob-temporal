# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/signal_query_options"

RSpec.describe ActiveJob::Temporal::SignalQueryOptions do
  it "allows ActiveJob classes to declare temporal signals and queries" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "SignalQueryOptionsJob"

      temporal_signal :progress
      temporal_signal(:append_event) { |state, event| (state["events"] ||= []) << event }
      temporal_query(:progress) { |state| state["progress"] }
      temporal_query(:events) { |state| state["events"] || [] }
    end

    state = {}
    job_class.temporal_signal_handlers.fetch("progress").call(state, 50)
    job_class.temporal_signal_handlers.fetch("append_event").call(state, "started")

    expect(job_class.temporal_signal_handler_names).to contain_exactly("progress", "append_event")
    expect(job_class.temporal_query_handler_names).to contain_exactly("progress", "events")
    expect(job_class.temporal_query_handlers.fetch("progress").call(state)).to eq(50)
    expect(job_class.temporal_query_handlers.fetch("events").call(state)).to eq(["started"])
  end

  it "inherits handlers and allows subclasses to add their own" do
    parent_class = Class.new(ActiveJob::Base) do
      def self.name = "ParentSignalQueryOptionsJob"

      temporal_signal :progress
      temporal_query(:progress) { |state| state["progress"] }
    end

    child_class = Class.new(parent_class) do
      def self.name = "ChildSignalQueryOptionsJob"

      temporal_signal :checkpoint
      temporal_query(:checkpoint) { |state| state["checkpoint"] }
    end

    expect(child_class.temporal_signal_handler_names).to contain_exactly("progress", "checkpoint")
    expect(child_class.temporal_query_handler_names).to contain_exactly("progress", "checkpoint")
  end

  it "rejects invalid handler names" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "InvalidSignalQueryOptionsJob"
    end

    expect { job_class.temporal_signal("invalid-name") }
      .to raise_error(ArgumentError, /signal and query names/)
    expect { job_class.temporal_query("1invalid") { nil } }
      .to raise_error(ArgumentError, /signal and query names/)
  end

  it "rejects custom handlers that conflict with built-in workflow interactions" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "ReservedSignalQueryOptionsJob"
    end

    expect { job_class.temporal_signal(:pause) }
      .to raise_error(ArgumentError, /reserved/)
    expect { job_class.temporal_query(:state) { nil } }
      .to raise_error(ArgumentError, /reserved/)
  end

  it "requires temporal queries to provide a block" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "QueryBlockSignalQueryOptionsJob"
    end

    expect { job_class.temporal_query(:progress) }
      .to raise_error(ArgumentError, /temporal_query requires a block/)
  end
end
