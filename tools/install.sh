#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_EXPORT_FILE="${SCRIPT_DIR}/.bundle-env"

cd "$REPO_ROOT"

if ! command -v rvm >/dev/null 2>&1; then
  echo "RVM with Ruby 4.0.3 is required for local repository tooling." >&2
  exit 1
fi

RUBY_COMMAND=(rvm 4.0.3 do)

if [[ -f "package.json" && -f "Gemfile" ]]; then
  echo "Multiple manifest files detected. This installer currently supports Ruby (Gemfile) projects only." >&2
  exit 1
fi

if [[ -f "Gemfile" ]]; then
  PROJECT_TYPE="ruby"
else
  echo "No supported manifest found. Expected Gemfile for Ruby projects." >&2
  exit 1
fi

if [[ "$PROJECT_TYPE" == "ruby" ]]; then
  if ! "${RUBY_COMMAND[@]}" bundle --version >/dev/null 2>&1; then
    cat >&2 <<'MSG'
Bundler is required but was not found for Ruby 4.0.3.
Install it with: rvm 4.0.3 do gem install bundler
MSG
    exit 1
  fi

  export BUNDLE_GEMFILE="$REPO_ROOT/Gemfile"
  export BUNDLE_PATH="${BUNDLE_PATH:-$REPO_ROOT/vendor/bundle}"
  PATH_UPDATE="$REPO_ROOT/bin"

  mkdir -p "$REPO_ROOT/bin" "$BUNDLE_PATH"

  if [[ ":${PATH:-}:" != *":$PATH_UPDATE:"* ]]; then
    export PATH="$PATH_UPDATE:$PATH"
  fi

  # Provide a reusable environment file for other scripts to source.
  PATH_TEMPLATE='${PATH:-}'
  cat >"$ENV_EXPORT_FILE" <<EOF
# shellcheck shell=bash
export BUNDLE_GEMFILE="$BUNDLE_GEMFILE"
export BUNDLE_PATH="$BUNDLE_PATH"
if [[ ":$PATH_TEMPLATE:" != *":$PATH_UPDATE:"* ]]; then
  export PATH="$PATH_UPDATE:$PATH_TEMPLATE"
fi
EOF

  "${RUBY_COMMAND[@]}" bundle config set --local path "$BUNDLE_PATH" >/dev/null

  if "${RUBY_COMMAND[@]}" bundle check >/dev/null 2>&1; then
    exit 0
  fi

  "${RUBY_COMMAND[@]}" bundle install \
    --jobs "${BUNDLE_JOBS:-4}" \
    --retry "${BUNDLE_RETRY:-3}" \
    --path "$BUNDLE_PATH"
fi
