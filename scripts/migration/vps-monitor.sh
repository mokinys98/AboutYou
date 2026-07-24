#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root" >&2
  exit 2
fi

config_file="${ABOUTYOU_MONITOR_CONFIG:-/etc/aboutyou-monitor/monitor.env}"
state_dir="${ABOUTYOU_MONITOR_STATE_DIR:-/var/lib/aboutyou-monitor}"
state_file="$state_dir/last-status"

if [ -f "$config_file" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$config_file"
  set +a
fi

DISK_MAX_PERCENT="${DISK_MAX_PERCENT:-80}"
BACKUP_MAX_AGE_SECONDS="${BACKUP_MAX_AGE_SECONDS:-129600}"
SUPABASE_HEALTH_URL="${SUPABASE_HEALTH_URL:-https://supabase-staging.rinkissaupigiausia.online/auth/v1/.well-known/jwks.json}"
API_HEALTH_URL="${API_HEALTH_URL:-https://aboutyou-private-catalog-api-staging.aurimas-zvirb.workers.dev/health}"
SMTP_CONFIG_FILE="${SMTP_CONFIG_FILE:-/srv/supabase/docker/.env}"
ALERT_EMAIL_SUBJECT_PREFIX="${ALERT_EMAIL_SUBJECT_PREFIX:-AboutYou VPS monitor}"

env_file_value() {
  local key="$1"
  local file="$2"
  [ -r "$file" ] || return 0
  awk -F= -v wanted="$key" '$1 == wanted {
    value = substr($0, index($0, "=") + 1)
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
    print value
    exit
  }' "$file"
}

SMTP_HOST="${SMTP_HOST:-$(env_file_value SMTP_HOST "$SMTP_CONFIG_FILE")}"
SMTP_PORT="${SMTP_PORT:-$(env_file_value SMTP_PORT "$SMTP_CONFIG_FILE")}"
SMTP_USER="${SMTP_USER:-$(env_file_value SMTP_USER "$SMTP_CONFIG_FILE")}"
SMTP_PASSWORD="${SMTP_PASSWORD:-$(env_file_value SMTP_PASS "$SMTP_CONFIG_FILE")}"
SMTP_FROM="${SMTP_FROM:-$(env_file_value SMTP_ADMIN_EMAIL "$SMTP_CONFIG_FILE")}"
SMTP_SENDER_NAME="${SMTP_SENDER_NAME:-$(env_file_value SMTP_SENDER_NAME "$SMTP_CONFIG_FILE")}"
SMTP_PORT="${SMTP_PORT:-587}"

install -d -m 0700 "$state_dir"

declare -a failures=()
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failures+=("$1"); }
info() { printf 'INFO %s\n' "$1"; }

http_check() {
  local name="$1"
  local url="$2"
  local expected_pattern="$3"
  local body code
  body="$(mktemp)"
  code="$(curl -sS --max-time 20 -o "$body" -w '%{http_code}' "$url" || true)"
  if [ "$code" = "200" ] && grep -q "$expected_pattern" "$body"; then
    pass "$name HTTP 200"
  else
    fail "$name unhealthy HTTP ${code:-request-failed}"
  fi
  rm -f -- "$body"
}

send_alert_email() {
  local message="$1"
  local recipients body netrc scheme subject to_name failed_count=0
  local -a tls_args=()
  if [ -z "$SMTP_HOST" ] || [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASSWORD" ] || [ -z "$SMTP_FROM" ]; then
    printf 'WARN SMTP alert delivery not configured\n' >&2
    return 0
  fi
  recipients="$("${psql_cmd[@]}" -c "select email from public.team_members where role = 'admin' and active and position('@' in email) > 1 order by email;" 2>/dev/null || true)"
  if [ -z "$recipients" ]; then
    printf 'WARN no active admin recipients for SMTP alert\n' >&2
    return 0
  fi
  body="$(mktemp)"
  netrc="$(mktemp)"
  chmod 600 "$netrc"
  if [[ "$message" == *RECOVERED* ]]; then subject="$ALERT_EMAIL_SUBJECT_PREFIX RECOVERED"; else subject="$ALERT_EMAIL_SUBJECT_PREFIX FAILED"; fi
  if [ "$SMTP_PORT" = "465" ]; then scheme="smtps"; else scheme="smtp"; tls_args+=(--ssl-reqd); fi
  printf 'machine %s login %s password %s\n' "$SMTP_HOST" "$SMTP_USER" "$SMTP_PASSWORD" > "$netrc"
  {
    if [ -n "$SMTP_SENDER_NAME" ]; then printf 'From: %s <%s>\r\n' "$SMTP_SENDER_NAME" "$SMTP_FROM"; else printf 'From: %s\r\n' "$SMTP_FROM"; fi
    printf 'To: undisclosed-recipients:;\r\nSubject: %s\r\nDate: %s\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n%s\r\n' "$subject" "$(date -R)" "$message"
  } > "$body"
  while IFS= read -r to_name; do
    [ -n "$to_name" ] || continue
    if ! curl -fsS --max-time 30 "${tls_args[@]}" --url "${scheme}://${SMTP_HOST}:${SMTP_PORT}" \
      --netrc-file "$netrc" --mail-from "$SMTP_FROM" --mail-rcpt "$to_name" --upload-file "$body" >/dev/null; then
      failed_count=$((failed_count + 1))
    fi
  done <<< "$recipients"
  rm -f -- "$body" "$netrc"
  if [ "$failed_count" -gt 0 ]; then printf 'WARN SMTP alert delivery failed for %s recipient(s)\n' "$failed_count" >&2; fi
}

info "host=$(hostname) at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

disk_percent="$(df -P / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
if [[ "$disk_percent" =~ ^[0-9]+$ ]] && [ "$disk_percent" -lt "$DISK_MAX_PERCENT" ]; then
  pass "root disk ${disk_percent}% below ${DISK_MAX_PERCENT}%"
else
  fail "root disk ${disk_percent:-unknown}% threshold ${DISK_MAX_PERCENT}%"
fi

for service in docker cloudflared; do
  if systemctl is-active --quiet "$service"; then pass "$service active"; else fail "$service inactive"; fi
done

containers=(
  supabase-db supabase-studio supabase-kong supabase-auth supabase-meta
  supabase-rest supabase-storage supabase-edge-functions supabase-imgproxy
  supabase-pooler realtime-dev.supabase-realtime
)
for container in "${containers[@]}"; do
  state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
  if [ "$state" = "healthy" ] || [ "$state" = "running" ]; then
    pass "$container $state"
  else
    fail "$container ${state:-missing}"
  fi
done

http_check "Supabase JWKS" "$SUPABASE_HEALTH_URL" '"keys"'
http_check "Worker API" "$API_HEALTH_URL" '"ok"[[:space:]]*:[[:space:]]*true'

if systemctl is-active --quiet aboutyou-supabase-backup.timer; then
  pass "backup timer active"
else
  fail "backup timer inactive"
fi

backup_result="$(systemctl show aboutyou-supabase-backup.service -p Result --value 2>/dev/null || true)"
if [ "$backup_result" = "success" ]; then
  pass "latest backup service result success"
else
  fail "latest backup service result ${backup_result:-unknown}"
fi

latest_backup_epoch="$(find /srv/supabase/backups/encrypted -maxdepth 1 -type f -name 'aboutyou-supabase-*.tar.age' -printf '%T@\n' 2>/dev/null | sort -nr | head -n 1 || true)"
if [ -n "$latest_backup_epoch" ]; then
  latest_backup_epoch="${latest_backup_epoch%%.*}"
  backup_age=$(( $(date +%s) - latest_backup_epoch ))
  info "backup_age_seconds=$backup_age"
  if [ "$backup_age" -le "$BACKUP_MAX_AGE_SECONDS" ]; then
    pass "backup age within ${BACKUP_MAX_AGE_SECONDS}s"
  else
    fail "backup age ${backup_age}s exceeds ${BACKUP_MAX_AGE_SECONDS}s"
  fi
else
  fail "no local encrypted automatic backup"
fi

psql_cmd=(docker exec supabase-db psql -v ON_ERROR_STOP=1 -At -U postgres -d postgres)
refresh="$("${psql_cmd[@]}" -c "select requested_version||'|'||completed_version||'|'||last_status||'|'||coalesce(last_error,'') from public.catalog_read_model_refresh_state;" 2>/dev/null || true)"
info "refresh_state=${refresh:-missing}"
if printf '%s' "$refresh" | awk -F'|' 'NF >= 4 && $1 == $2 && ($3 == "refreshed" || $3 == "clean") && $4 == "" {ok=1} END {exit !ok}'; then
  pass "read model refresh current"
else
  fail "read model refresh stale or failed"
fi

cron_count="$("${psql_cmd[@]}" -c "select count(*) from cron.job where active and jobname like 'catalog-read-model-refresh%';" 2>/dev/null || true)"
if [ "$cron_count" = "2" ]; then pass "two refresh cron jobs active"; else fail "refresh cron count ${cron_count:-unknown}"; fi

cron_failures="$("${psql_cmd[@]}" -c "select count(*) from cron.job_run_details where status = 'failed' and start_time >= now() - interval '30 minutes' and jobid in (select jobid from cron.job where jobname like 'catalog-read-model-refresh%');" 2>/dev/null || true)"
if [ "$cron_failures" = "0" ]; then pass "no refresh cron failures in 30m"; else fail "refresh cron failures in 30m ${cron_failures:-unknown}"; fi

previous_status="$(cat "$state_file" 2>/dev/null || true)"
if [ "${#failures[@]}" -gt 0 ]; then
  printf 'failed\n' > "$state_file"
  summary="AboutYou VPS monitor FAILED on $(hostname): $(IFS='; '; echo "${failures[*]}")"
  printf '%s\n' "$summary" >&2
  if [ "$previous_status" != "failed" ]; then send_alert_email "$summary"; fi
  exit 1
fi

printf 'ok\n' > "$state_file"
if [ "$previous_status" = "failed" ]; then
  send_alert_email "AboutYou VPS monitor RECOVERED on $(hostname)"
fi
printf 'SUMMARY all monitoring checks passed\n'
