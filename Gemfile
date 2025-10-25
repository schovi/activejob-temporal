# frozen_string_literal: true

source "https://rubygems.org"

gemspec

vendor_temporalio_sdk = File.expand_path("vendor/temporalio-sdk", __dir__)

if Dir.exist?(vendor_temporalio_sdk)
  # Temporary shim until temporalio-sdk is published to RubyGems.
  gem "temporalio-sdk", "~> 1.0", path: vendor_temporalio_sdk
end
