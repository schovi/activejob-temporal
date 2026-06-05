# frozen_string_literal: true

require "spec_helper"
require "active_job"

describe ActiveJob::Temporal::TemporalOptions do
  let(:job_class_under_test) do
    Class.new(ActiveJob::Base) do
      def self.name
        "TestTimeoutJob"
      end
    end
  end

  describe ".temporal_options" do
    describe "when called without arguments" do
      it "returns an empty hash by default" do
        assert_empty job_class_under_test.temporal_options
      end

      it "returns stored options after setting them" do
        job_class_under_test.temporal_options(start_to_close_timeout: 300)
        assert_equal({ start_to_close_timeout: 300 }, job_class_under_test.temporal_options)
      end

      it "inherits options from parent job classes" do
        parent_class = Class.new(ActiveJob::Base) do
          temporal_options start_to_close_timeout: 300
        end
        child_class = Class.new(parent_class)

        assert_equal({ start_to_close_timeout: 300 }, child_class.temporal_options)
      end
    end

    describe "when setting timeout options" do
      it "accepts integer timeout values" do
        job_class_under_test.temporal_options(start_to_close_timeout: 300)
        assert_equal 300, job_class_under_test.temporal_options[:start_to_close_timeout]
      end

      it "accepts float timeout values" do
        job_class_under_test.temporal_options(heartbeat_timeout: 30.5)
        assert_equal 30.5, job_class_under_test.temporal_options[:heartbeat_timeout]
      end

      it "accepts ActiveSupport::Duration and converts to float" do
        job_class_under_test.temporal_options(start_to_close_timeout: 2.hours)
        assert_equal 7200.0, job_class_under_test.temporal_options[:start_to_close_timeout]
      end

      it "accepts multiple timeout options" do
        options = {
          start_to_close_timeout: 1.hour,
          heartbeat_timeout: 30.seconds,
          schedule_to_start_timeout: 5.minutes,
          schedule_to_close_timeout: 2.hours
        }
        job_class_under_test.temporal_options(options)

        result = job_class_under_test.temporal_options
        assert_equal 3600.0, result[:start_to_close_timeout]
        assert_equal 30.0, result[:heartbeat_timeout]
        assert_equal 300.0, result[:schedule_to_start_timeout]
        assert_equal 7200.0, result[:schedule_to_close_timeout]
      end

      it "allows child job classes to replace inherited options" do
        parent_class = Class.new(ActiveJob::Base) do
          temporal_options start_to_close_timeout: 300
        end
        child_class = Class.new(parent_class) do
          temporal_options heartbeat_timeout: 30
        end

        assert_equal({ heartbeat_timeout: 30 }, child_class.temporal_options)
        assert_equal({ start_to_close_timeout: 300 }, parent_class.temporal_options)
      end

      it "allows child job classes to merge inherited options explicitly" do
        parent_class = Class.new(ActiveJob::Base) do
          temporal_options start_to_close_timeout: 300
        end
        child_class = Class.new(parent_class) do
          temporal_options parent_class.temporal_options.merge(heartbeat_timeout: 30)
        end
        expected_options = {
          start_to_close_timeout: 300,
          heartbeat_timeout: 30
        }

        assert_equal expected_options, child_class.temporal_options
      end

      it "keeps sibling job class options isolated" do
        parent_class = Class.new(ActiveJob::Base) do
          temporal_options start_to_close_timeout: 300
        end
        override_child_class = Class.new(parent_class) do
          temporal_options heartbeat_timeout: 30
        end
        inherited_child_class = Class.new(parent_class)

        assert_equal({ heartbeat_timeout: 30 }, override_child_class.temporal_options)
        assert_equal({ start_to_close_timeout: 300 }, inherited_child_class.temporal_options)
      end

      it "allows child job classes to clear inherited options" do
        parent_class = Class.new(ActiveJob::Base) do
          temporal_options start_to_close_timeout: 300
        end
        child_class = Class.new(parent_class) do
          temporal_options({})
        end

        assert_empty child_class.temporal_options
      end
    end

    describe "when invalid keys are provided" do
      it "raises ArgumentError for unknown keys" do
        error = assert_raises(ArgumentError) do
          job_class_under_test.temporal_options(invalid_timeout: 100)
        end
        assert_match(/Invalid temporal_options keys: invalid_timeout/, error.message)
      end

      it "raises ArgumentError for multiple unknown keys" do
        error = assert_raises(ArgumentError) do
          job_class_under_test.temporal_options(
            start_to_close_timeout: 300,
            bad_key: 100,
            another_bad_key: 200
          )
        end
        assert_match(/Invalid temporal_options keys/, error.message)
      end
    end

    describe "when invalid value types are provided" do
      it "raises ArgumentError for string values" do
        error = assert_raises(ArgumentError) do
          job_class_under_test.temporal_options(start_to_close_timeout: "300")
        end
        assert_match(/Timeout values must be numeric or ActiveSupport::Duration/, error.message)
      end

      it "raises ArgumentError for nil values" do
        error = assert_raises(ArgumentError) do
          job_class_under_test.temporal_options(heartbeat_timeout: nil)
        end
        assert_match(/Timeout values must be numeric or ActiveSupport::Duration/, error.message)
      end

      it "raises ArgumentError for array values" do
        error = assert_raises(ArgumentError) do
          job_class_under_test.temporal_options(start_to_close_timeout: [300])
        end
        assert_match(/Timeout values must be numeric or ActiveSupport::Duration/, error.message)
      end
    end

    describe "valid timeout keys" do
      it "accepts start_to_close_timeout" do
        job_class_under_test.temporal_options(start_to_close_timeout: 300)

        assert_equal 300, job_class_under_test.temporal_options[:start_to_close_timeout]
      end

      it "accepts schedule_to_close_timeout" do
        job_class_under_test.temporal_options(schedule_to_close_timeout: 600)

        assert_equal 600, job_class_under_test.temporal_options[:schedule_to_close_timeout]
      end

      it "accepts schedule_to_start_timeout" do
        job_class_under_test.temporal_options(schedule_to_start_timeout: 120)

        assert_equal 120, job_class_under_test.temporal_options[:schedule_to_start_timeout]
      end

      it "accepts heartbeat_timeout" do
        job_class_under_test.temporal_options(heartbeat_timeout: 30)

        assert_equal 30, job_class_under_test.temporal_options[:heartbeat_timeout]
      end
    end
  end

  describe "integration with ActiveJob::Base" do
    it "automatically includes TemporalOptions in ActiveJob::Base" do
      assert_includes ActiveJob::Base.included_modules, ActiveJob::Temporal::TemporalOptions
    end

    it "allows real job classes to use temporal_options" do
      job_class = Class.new(ActiveJob::Base) do
        temporal_options start_to_close_timeout: 10.minutes
      end

      assert_equal 600.0, job_class.temporal_options[:start_to_close_timeout]
    end
  end
end
