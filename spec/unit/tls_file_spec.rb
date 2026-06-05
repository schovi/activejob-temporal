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

  it "rejects symlink paths" do
    Dir.mktmpdir do |directory|
      target_path = File.join(directory, "target.pem")
      symlink_path = File.join(directory, "client.pem")
      File.write(target_path, "certificate")
      File.symlink(target_path, symlink_path)

      refute described_class.readable_regular_file?(symlink_path)
      error = assert_raises(described_class::Error) { described_class.read(symlink_path) }
      assert_match(/must not be a symlink/, error.message)
    end
  end
end
