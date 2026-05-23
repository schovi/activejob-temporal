# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"

RSpec.describe ActiveJob::Temporal::RailsEnvironmentLoader do
  around do |example|
    current_directory = Dir.pwd
    example.run
  ensure
    Dir.chdir(current_directory)
  end

  it "continues silently for the default root when no Rails app is present" do
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        result = described_class.resolve(".")

        expect(result).not_to be_loaded
        expect(result.warnings).to be_empty
      end
    end
  end

  it "fails for an explicit missing Rails root" do
    Dir.mktmpdir do |directory|
      missing_root = File.join(directory, "missing")

      expect { described_class.resolve(missing_root) }
        .to raise_error(described_class::Error, /Cannot find Rails application/)
    end
  end

  it "warns and continues for an explicit non-Rails directory" do
    Dir.mktmpdir do |directory|
      result = described_class.resolve(directory)

      expect(result).not_to be_loaded
      expect(result.warnings).to include("Warning: #{directory} does not appear to be a Rails application")
    end
  end

  it "requires the canonical Rails environment path" do
    Dir.mktmpdir do |directory|
      rails_root = create_rails_root(directory)
      loaded_paths = []
      warning_io = StringIO.new

      result = described_class.load!(
        rails_root: rails_root,
        warning_io: warning_io,
        require_environment: ->(path) { loaded_paths << path }
      )

      expect(result).to be_loaded
      expect(loaded_paths).to eq([File.realpath(File.join(rails_root, "config", "environment.rb"))])
      expect(warning_io.string).to eq("")
    end
  end

  it "fails when a Rails app is missing config/environment.rb" do
    Dir.mktmpdir do |directory|
      rails_root = create_rails_root(directory, environment: false)

      expect { described_class.resolve(rails_root) }
        .to raise_error(described_class::Error, /Cannot find Rails environment/)
    end
  end

  it "fails when config/environment.rb resolves outside the Rails root" do
    Dir.mktmpdir do |directory|
      rails_root = create_rails_root(directory, environment: false)
      outside_environment_path = File.join(directory, "environment.rb")
      File.write(outside_environment_path, "# outside\n")
      File.symlink(outside_environment_path, File.join(rails_root, "config", "environment.rb"))

      expect { described_class.resolve(rails_root) }
        .to raise_error(described_class::Error, /outside RAILS_ROOT/)
    end
  end

  it "fails when the Rails root or config files are writable by group or world" do
    Dir.mktmpdir do |directory|
      rails_root = create_rails_root(directory)
      environment_path = File.join(rails_root, "config", "environment.rb")
      File.chmod(0o664, environment_path)

      expect { described_class.resolve(rails_root) }
        .to raise_error(described_class::Error, /group- or world-writable path/)
    ensure
      File.chmod(0o644, environment_path) if environment_path && File.exist?(environment_path)
    end
  end

  def create_rails_root(parent_directory, environment: true)
    rails_root = File.join(parent_directory, "app")
    config_path = File.join(rails_root, "config")
    FileUtils.mkdir_p(config_path)
    File.write(File.join(config_path, "application.rb"), "# application\n")
    File.write(File.join(config_path, "environment.rb"), "# environment\n") if environment
    rails_root
  end
end
