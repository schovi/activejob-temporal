#!/bin/bash
# Security check script for local development
# Run before commit: ./tools/security-check.sh

set -e

if ! command -v rvm >/dev/null 2>&1; then
  echo "RVM with Ruby 4.0.3 is required for local repository tooling." >&2
  exit 1
fi

RUBY_COMMAND=(rvm 4.0.3 do)

echo "🔒 Running security checks..."

echo "  ✓ Checking gem vulnerabilities..."
"${RUBY_COMMAND[@]}" bundle exec bundle-audit check --update || {
  echo "  ✗ bundle-audit found vulnerabilities!"
  exit 1
}

if "${RUBY_COMMAND[@]}" bash -lc 'command -v brakeman' &> /dev/null; then
  if [ -d "app" ] && [ -d "config" ]; then
    echo "  ✓ Running Brakeman code scan..."
    "${RUBY_COMMAND[@]}" brakeman --no-pager --quiet --exit-on-warn || {
      echo "  ✗ Brakeman found security issues!"
      exit 1
    }
  else
    echo "  ⊘ Brakeman skipped (not a Rails app)"
  fi
else
  echo "  ⊘ Brakeman not installed (optional)"
fi

echo ""
echo "✅ All security checks passed!"
echo ""
