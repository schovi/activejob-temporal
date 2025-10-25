#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export BUNDLE_GEMFILE="$REPO_ROOT/Gemfile"
export BUNDLE_PATH="${BUNDLE_PATH:-$REPO_ROOT/vendor/bundle}"
PATH_ENTRY="$REPO_ROOT/bin"
if [[ ":$PATH:" != *":$PATH_ENTRY:"* ]]; then
  export PATH="$PATH_ENTRY:$PATH"
fi

bash "$SCRIPT_DIR/install.sh" >/dev/null

cd "$REPO_ROOT"
report_file="$(mktemp -t rubocop-json.XXXXXX)"
trap 'rm -f "$report_file"' EXIT

rubocop_status=0
if ! bundle exec rubocop --format json >"$report_file"; then
  rubocop_status=$?
fi

ruby - "$report_file" <<'RUBY'
require "json"
path = ARGV.fetch(0)
content = File.size?(path) ? File.read(path) : ""
data = if content.strip.empty?
         {"files" => []}
       else
         begin
           JSON.parse(content)
         rescue JSON::ParserError => e
           STDERR.puts("Failed to parse RuboCop output: #{e.message}")
           {"files" => []}
         end
       end
results = data.fetch("files", []).flat_map do |file|
  file.fetch("offenses", []).map do |offense|
    location = offense.fetch("location", {})
    {
      type: offense["severity"] || offense["cop_name"] || "lint",
      path: file["path"],
      obj: offense["cop_name"] || "",
      message: offense["message"] || "",
      line: location["line"] ? location["line"].to_s : "",
      column: location["column"] ? location["column"].to_s : ""
    }
  end
end
puts JSON.generate(results)
RUBY

exit "$rubocop_status"
