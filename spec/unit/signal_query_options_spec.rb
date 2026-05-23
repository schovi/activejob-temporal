# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/signal_query_options"

RSpec.describe ActiveJob::Temporal::SignalQueryOptions do
  it "allows ActiveJob classes to declare temporal signals, queries, and updates" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "SignalQueryOptionsJob"

      temporal_signal :progress
      temporal_signal(:append_event) { |state, event| (state["events"] ||= []) << event }
      temporal_query(:progress) { |state| state["progress"] }
      temporal_query(:events) { |state| state["events"] || [] }
      temporal_update(:advance_progress) { |state, value| state["progress"] = value }
    end

    state = {}
    job_class.temporal_signal_handlers.fetch("progress").call(state, 50)
    job_class.temporal_signal_handlers.fetch("append_event").call(state, "started")

    expect(job_class.temporal_signal_handler_names).to contain_exactly("progress", "append_event")
    expect(job_class.temporal_query_handler_names).to contain_exactly("progress", "events")
    expect(job_class.temporal_update_handler_names).to contain_exactly("advance_progress")
    expect(job_class.temporal_query_handlers.fetch("progress").call(state)).to eq(50)
    expect(job_class.temporal_query_handlers.fetch("events").call(state)).to eq(["started"])
    expect(job_class.temporal_update_handlers.fetch("advance_progress").call(state, 75)).to eq(75)
  end

  it "inherits handlers and allows subclasses to add their own" do
    parent_class = Class.new(ActiveJob::Base) do
      def self.name = "ParentSignalQueryOptionsJob"

      temporal_signal :progress
      temporal_query(:progress) { |state| state["progress"] }
      temporal_update(:progress) { |state, value| state["progress"] = value }
    end

    child_class = Class.new(parent_class) do
      def self.name = "ChildSignalQueryOptionsJob"

      temporal_signal :checkpoint
      temporal_query(:checkpoint) { |state| state["checkpoint"] }
      temporal_update(:checkpoint) { |state, value| state["checkpoint"] = value }
    end

    expect(child_class.temporal_signal_handler_names).to contain_exactly("progress", "checkpoint")
    expect(child_class.temporal_query_handler_names).to contain_exactly("progress", "checkpoint")
    expect(child_class.temporal_update_handler_names).to contain_exactly("progress", "checkpoint")
  end

  it "rejects invalid handler names" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "InvalidSignalQueryOptionsJob"
    end

    expect { job_class.temporal_signal("invalid-name") }
      .to raise_error(ArgumentError, /signal and query names/)
    expect { job_class.temporal_query("1invalid") { nil } }
      .to raise_error(ArgumentError, /signal and query names/)
    expect { job_class.temporal_update("invalid-name") { nil } }
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

  it "requires temporal updates to provide a block" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "UpdateBlockSignalQueryOptionsJob"
    end

    expect { job_class.temporal_update(:progress) }
      .to raise_error(ArgumentError, /temporal_update requires a block/)
  end
end
