# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "temporalio-sdk"
  spec.version = "1.0.0"
  spec.authors = ["Temporal"]
  spec.email = ["ruby@temporal.io"]
  spec.summary = "Stub Temporal SDK for development"
  spec.description = "Temporary development stub until the official temporalio-sdk gem is released."
  spec.homepage = "https://temporal.io"
  spec.license = "MIT"

  spec.files = Dir.glob("lib/**/*")
  spec.require_paths = ["lib"]
end
