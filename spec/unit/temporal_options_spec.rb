# frozen_string_literal: true

require "spec_helper"
require "active_job"

RSpec.describe ActiveJob::Temporal::TemporalOptions do
  # Create a test job class for testing
  let(:test_job_class) do
    Class.new(ActiveJob::Base) do
      def self.name
        "TestTimeoutJob"
      end
    end
  end

  describe ".temporal_options" do
    context "when called without arguments" do
      it "returns an empty hash by default" do
        expect(test_job_class.temporal_options).to eq({})
      end

      it "returns stored options after setting them" do
        test_job_class.temporal_options(start_to_close_timeout: 300)
        expect(test_job_class.temporal_options).to eq({ start_to_close_timeout: 300 })
      end
    end

    context "when setting timeout options" do
      it "accepts integer timeout values" do
        test_job_class.temporal_options(start_to_close_timeout: 300)
        expect(test_job_class.temporal_options[:start_to_close_timeout]).to eq(300)
      end

      it "accepts float timeout values" do
        test_job_class.temporal_options(heartbeat_timeout: 30.5)
        expect(test_job_class.temporal_options[:heartbeat_timeout]).to eq(30.5)
      end

      it "accepts ActiveSupport::Duration and converts to float" do
        test_job_class.temporal_options(start_to_close_timeout: 2.hours)
        expect(test_job_class.temporal_options[:start_to_close_timeout]).to eq(7200.0)
      end

      it "accepts multiple timeout options" do
        options = {
          start_to_close_timeout: 1.hour,
          heartbeat_timeout: 30.seconds,
          schedule_to_start_timeout: 5.minutes,
          schedule_to_close_timeout: 2.hours
        }
        test_job_class.temporal_options(options)

        result = test_job_class.temporal_options
        expect(result[:start_to_close_timeout]).to eq(3600.0)
        expect(result[:heartbeat_timeout]).to eq(30.0)
        expect(result[:schedule_to_start_timeout]).to eq(300.0)
        expect(result[:schedule_to_close_timeout]).to eq(7200.0)
      end
    end

    context "when invalid keys are provided" do
      it "raises ArgumentError for unknown keys" do
        expect {
          test_job_class.temporal_options(invalid_timeout: 100)
        }.to raise_error(ArgumentError, /Invalid temporal_options keys: invalid_timeout/)
      end

      it "raises ArgumentError for multiple unknown keys" do
        expect {
          test_job_class.temporal_options(
            start_to_close_timeout: 300,
            bad_key: 100,
            another_bad_key: 200
          )
        }.to raise_error(ArgumentError, /Invalid temporal_options keys/)
      end
    end

    context "when invalid value types are provided" do
      it "raises ArgumentError for string values" do
        expect {
          test_job_class.temporal_options(start_to_close_timeout: "300")
        }.to raise_error(ArgumentError, /Timeout values must be numeric or ActiveSupport::Duration/)
      end

      it "raises ArgumentError for nil values" do
        expect {
          test_job_class.temporal_options(heartbeat_timeout: nil)
        }.to raise_error(ArgumentError, /Timeout values must be numeric or ActiveSupport::Duration/)
      end

      it "raises ArgumentError for array values" do
        expect {
          test_job_class.temporal_options(start_to_close_timeout: [300])
        }.to raise_error(ArgumentError, /Timeout values must be numeric or ActiveSupport::Duration/)
      end
    end

    context "valid timeout keys" do
      it "accepts start_to_close_timeout" do
        expect {
          test_job_class.temporal_options(start_to_close_timeout: 300)
        }.not_to raise_error
      end

      it "accepts schedule_to_close_timeout" do
        expect {
          test_job_class.temporal_options(schedule_to_close_timeout: 600)
        }.not_to raise_error
      end

      it "accepts schedule_to_start_timeout" do
        expect {
          test_job_class.temporal_options(schedule_to_start_timeout: 120)
        }.not_to raise_error
      end

      it "accepts heartbeat_timeout" do
        expect {
          test_job_class.temporal_options(heartbeat_timeout: 30)
        }.not_to raise_error
      end
    end
  end

  describe "integration with ActiveJob::Base" do
    it "automatically includes TemporalOptions in ActiveJob::Base" do
      expect(ActiveJob::Base.included_modules).to include(ActiveJob::Temporal::TemporalOptions)
    end

    it "allows real job classes to use temporal_options" do
      job_class = Class.new(ActiveJob::Base) do
        temporal_options start_to_close_timeout: 10.minutes
      end

      expect(job_class.temporal_options[:start_to_close_timeout]).to eq(600.0)
    end
  end
end
