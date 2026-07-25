#!/usr/bin/env bash
set -euo pipefail

pending_ok() {
  local value="$1"
  printf '%s' "$value" | awk -F'|' -v max_age=900 '
    NF >= 5 && $1 == $2 && ($3 == "refreshed" || $3 == "clean") && $4 == "" {ok=1}
    NF >= 5 && $1 != $2 && $3 == "pending" && $5 >= 0 && $5 <= max_age {ok=1}
    END {exit !ok}'
}

assert_pass() { pending_ok "$1"; }
assert_fail() { if pending_ok "$1"; then echo "unexpected PASS: $1" >&2; exit 1; fi; }

assert_pass '210|209|pending||300'
assert_fail '210|209|pending||960'
assert_fail '210|209|failed|57014: timeout|0'
assert_pass '210|210|clean||-1'

storage_ok() {
  local paused="$1" health="$2" backup_active="$3"
  if [ "$paused" = "true" ] && [ "$backup_active" -eq 1 ]; then return 0; fi
  [ "$health" = "healthy" ] || [ "$health" = "running" ]
}

storage_ok true unhealthy 1
if storage_ok true unhealthy 0; then echo 'unexpected storage PASS' >&2; exit 1; fi
storage_ok false healthy 0
if storage_ok false unhealthy 1; then echo 'unexpected unhealthy PASS' >&2; exit 1; fi

echo 'PASS vps monitor fixture logic'
