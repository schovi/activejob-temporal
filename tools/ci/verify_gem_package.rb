# frozen_string_literal: true

require "rubygems/package"

gem_path = ARGV.fetch(0)
package = Gem::Package.new(gem_path)
spec = package.spec
files = spec.files.sort

def fail_check(message)
  warn(message)
  exit 1
end

expected_files = %w[
  CHANGELOG.md
  LICENSE
  README.md
  activejob-temporal.gemspec
  bin/temporal-worker
  lib/activejob-temporal.rb
  lib/activejob/temporal.rb
  lib/activejob/temporal/version.rb
]

missing_files = expected_files - files
fail_check("Gem package is missing expected files: #{missing_files.join(', ')}") if missing_files.any?

forbidden_patterns = [
  %r{\A\.github/},
  %r{\A\.codemachine/},
  %r{\Acoverage/},
  %r{\Adocs/},
  %r{\Aexamples/},
  %r{\Agemfiles/},
  %r{\Apkg/},
  %r{\Aspec/},
  %r{\Atmp/},
  %r{\Atools/},
  %r{\Avendor/},
  /\ACLAUDE\.md\z/,
  /\ACONTRIBUTING\.md\z/,
  /\AGemfile(?:\.lock)?\z/,
  /\ARakefile\z/,
  /\Adocker-compose\.yml\z/
]

forbidden_files = files.select do |file|
  forbidden_patterns.any? { |pattern| pattern.match?(file) }
end
fail_check("Gem package contains non-release files: #{forbidden_files.join(', ')}") if forbidden_files.any?

metadata = spec.metadata
fail_check("rubygems_mfa_required metadata must be true") unless metadata["rubygems_mfa_required"] == "true"
fail_check("documentation_uri metadata is required") if metadata["documentation_uri"].to_s.empty?
if metadata["source_code_uri"] == metadata["homepage_uri"]
  fail_check("source_code_uri metadata must differ from homepage_uri")
end

readme = File.read("README.md")
relative_doc_links = readme.scan(%r{\]\(((?:docs|examples)/[^)]+)\)}).flatten
if relative_doc_links.any?
  fail_check("README contains relative links not suitable for RubyGems: #{relative_doc_links.join(', ')}")
end

puts "Gem package verification passed for #{gem_path}"
