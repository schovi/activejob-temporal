# frozen_string_literal: true

require "test_helper"

class RetryableJobTest < ActiveJob::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.clear
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "transient failure succeeds on the third attempt" do
    attempt_key = "campaign-sync"
    RetryableJob
    error_class = Object.const_get(:RetryableJobError)

    assert_raises(error_class) do
      RetryableJob.new.perform("campaign sync", should_fail: true, attempt_key: attempt_key)
    end
    assert_raises(error_class) do
      RetryableJob.new.perform("campaign sync", should_fail: true, attempt_key: attempt_key)
    end
    assert_nothing_raised do
      RetryableJob.new.perform("campaign sync", should_fail: true, attempt_key: attempt_key)
    end
  end
end
