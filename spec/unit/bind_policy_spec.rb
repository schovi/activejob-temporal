# frozen_string_literal: true

require "spec_helper"

describe ActiveJob::Temporal::BindPolicy do
  describe ".public_bind?" do
    it "treats loopback binds as private" do
      refute described_class.public_bind?("127.0.0.1")
      refute described_class.public_bind?("::1")
      refute described_class.public_bind?("localhost")
    end

    it "treats wildcard and non-loopback binds as public" do
      assert described_class.public_bind?("0.0.0.0")
      assert described_class.public_bind?("::")
      assert described_class.public_bind?("192.168.1.10")
      assert described_class.public_bind?("worker.internal")
    end
  end

  describe ".allow_public_bind?" do
    it "recognizes explicit truthy opt-ins" do
      assert described_class.allow_public_bind?("true")
      assert described_class.allow_public_bind?("TRUE")
      assert described_class.allow_public_bind?("1")
      assert described_class.allow_public_bind?("yes")
      assert described_class.allow_public_bind?("on")
      refute described_class.allow_public_bind?("false")
      refute described_class.allow_public_bind?("0")
      refute described_class.allow_public_bind?("no")
      refute described_class.allow_public_bind?("off")
    end
  end

  describe ".validate!" do
    it "rejects public binds without explicit opt-in" do
      error = assert_raises(ArgumentError) do
        described_class.validate!(
          endpoint: "health check",
          bind_address: "0.0.0.0",
          allow_public_bind: false
        )
      end
      assert_match(/without explicit public bind opt-in/, error.message)
    end

    it "warns when public binds are explicitly allowed" do
      _stdout, stderr = capture_io do
        described_class.validate!(
          endpoint: "metrics",
          bind_address: "0.0.0.0",
          allow_public_bind: true
        )
      end

      assert_match(/Warning: exposing unauthenticated metrics endpoint/, stderr)
    end
  end
end
