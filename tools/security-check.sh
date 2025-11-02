#!/bin/bash
# Security check script for local development
# Run before commit: ./tools/security-check.sh

set -e

echo "🔒 Running security checks..."

# Check 1: bundle-audit
echo "  ✓ Checking gem vulnerabilities..."
gem list bundler-audit > /dev/null || gem install bundler-audit
bundle-audit update > /dev/null 2>&1 || true
bundle-audit check --update || {
  echo "  ✗ bundle-audit found vulnerabilities!"
  exit 1
}

# Check 2: brakeman (optional - only for Rails apps)
if command -v brakeman &> /dev/null; then
  # Only run if this looks like a Rails app (has app/ and config/ directories)
  if [ -d "app" ] && [ -d "config" ]; then
    echo "  ✓ Running Brakeman code scan..."
    brakeman --no-pager --quiet --exit-on-warn || {
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
