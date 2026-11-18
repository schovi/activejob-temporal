#!/usr/bin/env bash
set -euo pipefail

docker compose exec -T temporal temporal operator namespace describe -n test >/dev/null 2>&1 ||
  docker compose exec -T temporal temporal operator namespace create -n test

required_search_attributes_present() {
  local attributes attribute
  attributes=$(docker compose exec -T temporal temporal operator search-attribute list -n test 2>/dev/null) || return 1
  for attribute in ajClass ajQueue ajJobId ajEnqueuedAt ajTenantId ajTags; do
    grep -qw "$attribute" <<<"$attributes" || return 1
  done
}

for ((attempt = 1; attempt <= 60; attempt++)); do
  if required_search_attributes_present; then
    # Namespace metadata can be readable before workflow RPCs can use it.
    if docker compose exec -T temporal temporal workflow list -n test --limit 1 --page-size 1 >/dev/null; then
      exit 0
    fi
  else
    docker compose exec -T temporal temporal operator search-attribute create -n test \
      --name ajClass --type Keyword \
      --name ajQueue --type Keyword \
      --name ajJobId --type Keyword \
      --name ajEnqueuedAt --type Datetime \
      --name ajTenantId --type Int \
      --name ajTags --type KeywordList || true
  fi
  sleep 1
done

echo "Temporal namespace test did not become ready with the required search attributes" >&2
exit 1
