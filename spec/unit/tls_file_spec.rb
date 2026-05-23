# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe ActiveJob::Temporal::TLSFile do
  it "reads regular files" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "client.pem")
      File.write(path, "certificate")

      expect(described_class.read(path)).to eq("certificate")
      expect(described_class.readable_regular_file?(path)).to be(true)
    end
  end

  it "returns nil for blank paths" do
    expect(described_class.read(nil)).to be_nil
    expect(described_class.read("")).to be_nil
  end

  it "rejects symlink paths" do
    Dir.mktmpdir do |directory|
      target_path = File.join(directory, "target.pem")
      symlink_path = File.join(directory, "client.pem")
      File.write(target_path, "certificate")
      File.symlink(target_path, symlink_path)

      expect(described_class.readable_regular_file?(symlink_path)).to be(false)
      expect { described_class.read(symlink_path) }
        .to raise_error(described_class::Error, /must not be a symlink/)
    end
  end
end
