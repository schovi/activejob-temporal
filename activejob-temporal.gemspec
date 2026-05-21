# frozen_string_literal: true

require_relative "lib/activejob/temporal/version"

Gem::Specification.new do |spec|
  spec.name = "activejob-temporal"
  spec.version = ActiveJob::Temporal::VERSION
  spec.authors = ["Temporal Technologies", "Ruby Community"]
  spec.email = ["ruby@temporal.io"]

  spec.summary = "Rails ActiveJob adapter backed by Temporal Workflows"
  spec.description = <<~DESC
    activejob-temporal bridges Rails ActiveJob with Temporal's durable execution engine.
    It provides a drop-in ActiveJob adapter, Temporal workflows, and supporting tooling
    so Rails apps gain fault-tolerant scheduling, retries, and observability with minimal changes.
  DESC
  spec.homepage = "https://github.com/schovi/activejob-temporal"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      f.start_with?("spec/", "docs/", "examples/", "tmp/", "tools/", ".codemachine/", ".github/") ||
        f.match?(%r{^(\.|docker-compose\.yml|coverage/|Gemfile|Rakefile)})
    end
  end
  spec.bindir = "bin"
  spec.executables = ["temporal-worker"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activejob", ">= 7.2", "< 9"
  spec.add_dependency "activemodel", ">= 7.2", "< 9"
  spec.add_dependency "concurrent-ruby", "~> 1.1"
  spec.add_dependency "globalid", ">= 0.3"
  spec.add_dependency "listen", "~> 3.9"
  spec.add_dependency "prometheus-client", "~> 4.2"
  spec.add_dependency "temporalio", ">= 1.4.0", "< 1.5"

  spec.add_development_dependency "benchmark-ips", "~> 2.14"
  spec.add_development_dependency "github_changelog_generator", "~> 1.18"
  spec.add_development_dependency "msgpack", "~> 1.8"
  spec.add_development_dependency "mutant-rspec", "~> 0.16"
  spec.add_development_dependency "rake", "~> 13.2"
  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rubocop", "~> 1.50"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "simplecov-lcov", "~> 0.9"
  spec.add_development_dependency "yard", "~> 0.9"
end
