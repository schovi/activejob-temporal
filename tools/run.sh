#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

bash "$SCRIPT_DIR/install.sh"

ENV_EXPORT_FILE="$SCRIPT_DIR/.bundle-env"
if [[ ! -f "$ENV_EXPORT_FILE" ]]; then
  echo "Environment export file not found at $ENV_EXPORT_FILE. Run tools/install.sh manually to debug." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_EXPORT_FILE"

cd "$REPO_ROOT"
bundle exec rake
