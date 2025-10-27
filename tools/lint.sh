#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

bash "$SCRIPT_DIR/install.sh" >/dev/null

ENV_EXPORT_FILE="$SCRIPT_DIR/.bundle-env"
if [[ ! -f "$ENV_EXPORT_FILE" ]]; then
  echo "Environment export file not found at $ENV_EXPORT_FILE. Run tools/install.sh manually to debug." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_EXPORT_FILE"

cd "$REPO_ROOT"
if command -v mktemp >/dev/null 2>&1; then
  report_file="$(mktemp -t rubocop-json.XXXXXX)"
else
  tmpdir="${TMPDIR:-/tmp}"
  report_file="${tmpdir%/}/rubocop-json.$$.${RANDOM:-0}"
  : >"$report_file"
fi
trap 'rm -f "$report_file"' EXIT

rubocop_status=0
if ! bundle exec rubocop --format json --force-exclusion >"$report_file"; then
  rubocop_status=$?
fi

export RUBOCOP_STATUS="$rubocop_status"
ruby - "$report_file" <<'RUBY'
require "json"
path = ARGV.fetch(0)
status = Integer(ENV.fetch("RUBOCOP_STATUS", "0"), 10)
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
critical_severities = %w[error fatal]
results = data.fetch("files", []).flat_map do |file|
  file.fetch("offenses", []).filter_map do |offense|
    severity = (offense["severity"] || "").downcase
    next unless critical_severities.include?(severity)

    location = offense.fetch("location", {})
    {
      "type" => severity,
      "path" => file["path"] || "",
      "obj" => offense["cop_name"] || "",
      "message" => offense["message"] || "",
      "line" => location["line"] ? location["line"].to_s : "",
      "column" => location["column"] ? location["column"].to_s : ""
    }
  end
end
STDOUT.write(JSON.generate(results))
STDOUT.flush

if status >= 2
  exit status
end

exit(results.empty? ? 0 : 1)
RUBY

ruby_status=$?

if (( rubocop_status >= 2 )) && (( ruby_status == 0 )); then
  exit "$rubocop_status"
fi

exit "$ruby_status"
