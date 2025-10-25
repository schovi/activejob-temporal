#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -f "Gemfile" ]]; then
  echo "Gemfile not found; cannot install Ruby dependencies." >&2
  exit 1
fi

if ! command -v bundle >/dev/null 2>&1; then
  cat >&2 <<'MSG'
Bundler is required but was not found in PATH.
Install it with: gem install bundler
MSG
  exit 1
fi

export BUNDLE_GEMFILE="$REPO_ROOT/Gemfile"
export BUNDLE_PATH="${BUNDLE_PATH:-$REPO_ROOT/vendor/bundle}"

mkdir -p "$REPO_ROOT/bin" "$BUNDLE_PATH"
PATH_UPDATE="$REPO_ROOT/bin"
if [[ ":$PATH:" != *":$PATH_UPDATE:"* ]]; then
  export PATH="$PATH_UPDATE:$PATH"
fi

bundle config set --local path "$BUNDLE_PATH" >/dev/null

if bundle check >/dev/null 2>&1; then
  exit 0
fi

bundle install \
  --jobs "${BUNDLE_JOBS:-4}" \
  --retry "${BUNDLE_RETRY:-3}" \
  --path "$BUNDLE_PATH"
