# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"
require "yard"

desc "Run the spec suite"
RSpec::Core::RakeTask.new(:spec)

RuboCop::RakeTask.new(:rubocop)

YARD::Rake::YardocTask.new(:yard)

desc "Default: run rubocop and specs"
task default: %i[rubocop spec]
