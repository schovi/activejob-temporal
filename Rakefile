# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"
require "yard"

desc "Run the spec suite"
task spec: %i[spec:unit spec:integration]

namespace :spec do
  desc "Run unit specs"
  RSpec::Core::RakeTask.new(:unit) do |t|
    t.pattern = "spec/unit/**/*_spec.rb"
    ENV["TEST_SUITE"] = "unit"
  end

  desc "Run integration specs"
  RSpec::Core::RakeTask.new(:integration) do |t|
    t.pattern = "spec/integration/**/*_spec.rb"
    ENV["TEST_SUITE"] = "integration"
  end
end

RuboCop::RakeTask.new(:rubocop)

YARD::Rake::YardocTask.new(:yard)

desc "Run performance benchmarks"
task :benchmark do
  ruby "spec/benchmarks/activejob_temporal_benchmark.rb"
end

desc "Default: run rubocop and specs"
task default: %i[rubocop spec]
