# frozen_string_literal: true

require "spec_helper"

RSpec.describe ActiveJob::Temporal::BindPolicy do
  describe ".public_bind?" do
    it "treats loopback binds as private" do
      expect(described_class.public_bind?("127.0.0.1")).to be(false)
      expect(described_class.public_bind?("::1")).to be(false)
      expect(described_class.public_bind?("localhost")).to be(false)
    end

    it "treats wildcard and non-loopback binds as public" do
      expect(described_class.public_bind?("0.0.0.0")).to be(true)
      expect(described_class.public_bind?("::")).to be(true)
      expect(described_class.public_bind?("192.168.1.10")).to be(true)
      expect(described_class.public_bind?("worker.internal")).to be(true)
    end
  end

  describe ".allow_public_bind?" do
    it "recognizes explicit truthy opt-ins" do
      expect(described_class.allow_public_bind?("true")).to be(true)
      expect(described_class.allow_public_bind?("1")).to be(true)
      expect(described_class.allow_public_bind?("yes")).to be(true)
      expect(described_class.allow_public_bind?("false")).to be(false)
    end
  end

  describe ".validate!" do
    it "rejects public binds without explicit opt-in" do
      expect do
        described_class.validate!(
          endpoint: "health check",
          bind_address: "0.0.0.0",
          allow_public_bind: false
        )
      end.to raise_error(ArgumentError, /without explicit public bind opt-in/)
    end

    it "warns when public binds are explicitly allowed" do
      expect do
        described_class.validate!(
          endpoint: "metrics",
          bind_address: "0.0.0.0",
          allow_public_bind: true
        )
      end.to output(/Warning: exposing unauthenticated metrics endpoint/).to_stderr
    end
  end
end
