# frozen_string_literal: true

require "spec_helper"
require "activejob/temporal/signal_query_options"

describe ActiveJob::Temporal::SignalQueryOptions do
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

    assert_unordered_equal %w[progress append_event], job_class.temporal_signal_handler_names
    assert_unordered_equal %w[progress events], job_class.temporal_query_handler_names
    assert_unordered_equal ["advance_progress"], job_class.temporal_update_handler_names
    assert_equal 50, job_class.temporal_query_handlers.fetch("progress").call(state)
    assert_equal ["started"], job_class.temporal_query_handlers.fetch("events").call(state)
    assert_equal 75, job_class.temporal_update_handlers.fetch("advance_progress").call(state, 75)
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

    assert_unordered_equal %w[progress checkpoint], child_class.temporal_signal_handler_names
    assert_unordered_equal %w[progress checkpoint], child_class.temporal_query_handler_names
    assert_unordered_equal %w[progress checkpoint], child_class.temporal_update_handler_names
  end

  it "rejects invalid handler names" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "InvalidSignalQueryOptionsJob"
    end

    error = assert_raises(ArgumentError) { job_class.temporal_signal("invalid-name") }
    assert_match(/signal and query names/, error.message)

    error = assert_raises(ArgumentError) { job_class.temporal_query("1invalid") { nil } }
    assert_match(/signal and query names/, error.message)

    error = assert_raises(ArgumentError) { job_class.temporal_update("invalid-name") { nil } }
    assert_match(/signal and query names/, error.message)
  end

  it "rejects custom handlers that conflict with built-in workflow interactions" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "ReservedSignalQueryOptionsJob"
    end

    error = assert_raises(ArgumentError) { job_class.temporal_signal(:pause) }
    assert_match(/reserved/, error.message)

    error = assert_raises(ArgumentError) { job_class.temporal_query(:state) { nil } }
    assert_match(/reserved/, error.message)
  end

  it "requires temporal queries to provide a block" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "QueryBlockSignalQueryOptionsJob"
    end

    error = assert_raises(ArgumentError) { job_class.temporal_query(:progress) }
    assert_match(/temporal_query requires a block/, error.message)
  end

  it "requires temporal updates to provide a block" do
    job_class = Class.new(ActiveJob::Base) do
      def self.name = "UpdateBlockSignalQueryOptionsJob"
    end

    error = assert_raises(ArgumentError) { job_class.temporal_update(:progress) }
    assert_match(/temporal_update requires a block/, error.message)
  end
end
