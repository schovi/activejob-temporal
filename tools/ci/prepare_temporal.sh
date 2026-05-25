#!/usr/bin/env bash
set -euo pipefail

services=("$@")
if ((${#services[@]} == 0)); then
  services=(postgresql temporal)
fi

docker compose up -d "${services[@]}"

for _ in {1..120}; do
  if docker compose exec -T temporal temporal operator namespace list >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! docker compose exec -T temporal temporal operator namespace list >/dev/null 2>&1; then
  docker compose logs temporal
  exit 1
fi

docker compose exec -T temporal temporal operator namespace describe test >/dev/null 2>&1 ||
  docker compose exec -T temporal temporal operator namespace create test

for _ in {1..60}; do
  if docker compose exec -T temporal temporal operator namespace describe test >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

required_search_attributes_present() {
  attributes=$(docker compose exec -T temporal temporal operator search-attribute list -n test 2>/dev/null || true)
  for attribute in ajClass ajQueue ajJobId ajEnqueuedAt ajTenantId ajTags; do
    if ! grep -q "$attribute" <<<"$attributes"; then
      return 1
    fi
  done
}

for _ in {1..60}; do
  if required_search_attributes_present; then
    exit 0
  fi
  docker compose exec -T temporal temporal operator search-attribute create -n test \
    --name ajClass --type Keyword \
    --name ajQueue --type Keyword \
    --name ajJobId --type Keyword \
    --name ajEnqueuedAt --type Datetime \
    --name ajTenantId --type Int \
    --name ajTags --type KeywordList || true
  sleep 1
done

required_search_attributes_present
