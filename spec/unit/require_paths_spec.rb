# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "require paths" do
  def run_ruby(source)
    Open3.capture3(
      RbConfig.ruby,
      "-Ilib",
      "-rbundler/setup",
      "-e",
      source,
      chdir: File.expand_path("../..", __dir__)
    )
  end

  it "loads the adapter path without worker runtime files or listen" do
    stdout, stderr, status = run_ruby(<<~RUBY)
      require "activejob/temporal"

      blocked = %r{/activejob/temporal/(certificate_watcher|worker_pool|worker_health|health_check_server|metrics_server|workflows/aj_workflow|workflows/dead_letter_workflow|activities/)}
      loaded = $LOADED_FEATURES.select { |feature| feature.match?(blocked) || feature.include?("/listen/") }

      abort loaded.join("\\n") unless loaded.empty?
    RUBY

    expect(status).to be_success, stderr
    expect(stdout).to eq("")
  end

  it "keeps the legacy require path on the adapter surface" do
    stdout, stderr, status = run_ruby(<<~RUBY)
      require "activejob-temporal"

      blocked = %r{/activejob/temporal/(certificate_watcher|worker_pool|worker_health|health_check_server|metrics_server|workflows/aj_workflow|workflows/dead_letter_workflow|activities/)}
      loaded = $LOADED_FEATURES.select { |feature| feature.match?(blocked) || feature.include?("/listen/") }

      abort loaded.join("\\n") unless loaded.empty?
    RUBY

    expect(status).to be_success, stderr
    expect(stdout).to eq("")
  end

  it "loads worker runtime files without loading listen" do
    stdout, stderr, status = run_ruby(<<~'RUBY')
      require "activejob/temporal/worker_runtime"

      required = [
        "activejob/temporal/worker_pool.rb",
        "activejob/temporal/worker_health.rb",
        "activejob/temporal/health_check_server.rb",
        "activejob/temporal/metrics_server.rb",
        "activejob/temporal/workflows/aj_workflow.rb",
        "activejob/temporal/workflows/dead_letter_workflow.rb",
        "activejob/temporal/activities/rate_limit_activity.rb",
        "activejob/temporal/activities/dependency_status_activity.rb",
        "activejob/temporal/activities/aj_runner_activity.rb"
      ]

      missing = required.reject { |suffix| $LOADED_FEATURES.any? { |feature| feature.end_with?(suffix) } }
      listen_loaded = $LOADED_FEATURES.any? { |feature| feature.include?("/listen/") }

      abort "missing: #{missing.join(", ")}" unless missing.empty?
      abort "listen loaded" if listen_loaded
    RUBY

    expect(status).to be_success, stderr
    expect(stdout).to eq("")
  end

  it "loads listen when certificate watching starts with the default listener" do
    stdout, stderr, status = run_ruby(<<~RUBY)
      require "tmpdir"
      require "activejob/temporal/worker_runtime"

      Dir.mktmpdir do |dir|
        certificate_path = File.join(dir, "client.pem")
        File.write(certificate_path, "cert")

        watcher = ActiveJob::Temporal::CertificateWatcher.new(
          paths: [certificate_path],
          reload_callback: -> {}
        ).start

        begin
          listen_loaded = $LOADED_FEATURES.any? { |feature| feature.include?("/listen/") }
          abort "listen not loaded" unless listen_loaded
        ensure
          watcher.stop
        end
      end
    RUBY

    expect(status).to be_success, stderr
    expect(stdout).to eq("")
  end

  it "does not load listen when only the certificate watcher file is required" do
    stdout, stderr, status = run_ruby(<<~RUBY)
      require "activejob/temporal/certificate_watcher"

      listen_loaded = $LOADED_FEATURES.any? { |feature| feature.include?("/listen/") }
      abort "listen loaded" if listen_loaded
    RUBY

    expect(status).to be_success, stderr
    expect(stdout).to eq("")
  end

  it "does not declare listen as a runtime dependency" do
    specification = Gem::Specification.load("activejob-temporal.gemspec")

    runtime_dependencies = specification.dependencies.select(&:runtime?).map(&:name)

    expect(runtime_dependencies).not_to include("listen")
  end
end
