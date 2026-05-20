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

# Check 1: bundle-audit
echo "  ✓ Checking gem vulnerabilities..."
if ! "${RUBY_COMMAND[@]}" gem list -i bundler-audit > /dev/null; then
  "${RUBY_COMMAND[@]}" gem install bundler-audit
fi
"${RUBY_COMMAND[@]}" bundle-audit update > /dev/null 2>&1 || true
"${RUBY_COMMAND[@]}" bundle-audit check --update || {
  echo "  ✗ bundle-audit found vulnerabilities!"
  exit 1
}

# Check 2: brakeman (optional - only for Rails apps)
if "${RUBY_COMMAND[@]}" bash -lc 'command -v brakeman' &> /dev/null; then
  # Only run if this looks like a Rails app (has app/ and config/ directories)
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
