# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

describe ActiveJob::Temporal::TLSFile do
  it "reads regular files" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "client.pem")
      File.write(path, "certificate")

      assert_equal "certificate", described_class.read(path)
      assert described_class.readable_regular_file?(path)
    end
  end

  it "returns nil for blank paths" do
    assert_nil described_class.read(nil)
    assert_nil described_class.read("")
  end

  it "follows symlinks to regular files" do
    Dir.mktmpdir do |directory|
      target_path = File.join(directory, "target.pem")
      symlink_path = File.join(directory, "client.pem")
      File.write(target_path, "certificate")
      File.symlink(target_path, symlink_path)

      assert described_class.readable_regular_file?(symlink_path)
      assert_equal "certificate", described_class.read(symlink_path)
    end
  end

  it "reads through a Kubernetes secret mount layout" do
    Dir.mktmpdir do |directory|
      data_directory = File.join(directory, "..2026_08_06_00_00_00.123456")
      Dir.mkdir(data_directory)
      File.write(File.join(data_directory, "tls.crt"), "certificate")
      File.symlink(data_directory, File.join(directory, "..data"))
      File.symlink(File.join("..data", "tls.crt"), File.join(directory, "tls.crt"))

      path = File.join(directory, "tls.crt")

      assert described_class.readable_regular_file?(path)
      assert_equal "certificate", described_class.read(path)
    end
  end

  it "rejects paths resolving to a directory" do
    Dir.mktmpdir do |directory|
      symlink_path = File.join(directory, "client.pem")
      File.symlink(directory, symlink_path)

      refute described_class.readable_regular_file?(symlink_path)
      error = assert_raises(described_class::Error) { described_class.read(symlink_path) }
      assert_match(/must point to a regular file/, error.message)
    end
  end

  it "rejects dangling symlinks" do
    Dir.mktmpdir do |directory|
      symlink_path = File.join(directory, "client.pem")
      File.symlink(File.join(directory, "missing.pem"), symlink_path)

      refute described_class.readable_regular_file?(symlink_path)
      error = assert_raises(described_class::Error) { described_class.read(symlink_path) }
      assert_match(/not readable/, error.message)
    end
  end
end
