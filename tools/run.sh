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

bash "$SCRIPT_DIR/install.sh"

cd "$REPO_ROOT"
bundle exec rake
