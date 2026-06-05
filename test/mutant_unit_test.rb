# frozen_string_literal: true

require "mutant/minitest/coverage"
require_relative "../spec/spec_helper"

# mutant-minitest discovers test/**/*_test.rb, while the migrated suite keeps
# the existing spec/ split for CI and developer workflows.
Minitest::Spec.cover "ActiveJob::Temporal::WorkflowIdBuilder#build"
Minitest::Spec.cover "ActiveJob::Temporal::WorkflowIdBuilder.default_for"

Dir[File.expand_path("../spec/unit/**/*_spec.rb", __dir__)].each do |path|
  require path
end
