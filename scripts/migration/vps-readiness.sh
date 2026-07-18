#!/usr/bin/env bash
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo bash scripts/migration/vps-readiness.sh" >&2
  exit 2
fi

stack_dir="/srv/supabase/docker"
r2_env="/etc/aboutyou-backup/r2.env"
failed=0

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; failed=$((failed + 1)); }
info() { printf 'INFO %s\n' "$1"; }

command_exists() {
  if command -v "$1" >/dev/null 2>&1; then pass "$1 installed"; else fail "$1 missing"; fi
}

info "host=$(hostname) kernel=$(uname -r)"
info "uptime=$(uptime -p)"
free -h
df -h / /boot 2>/dev/null || df -h /

if swapon --show --noheadings | grep -q .; then pass "swap active"; else fail "swap inactive"; fi

if ufw status 2>/dev/null | grep -q '^Status: active'; then pass "UFW active"; else fail "UFW inactive"; fi

sshd_effective="$(sshd -T 2>/dev/null || true)"
for expected in 'permitrootlogin no' 'passwordauthentication no' 'pubkeyauthentication yes'; do
  if printf '%s\n' "$sshd_effective" | grep -qx "$expected"; then pass "SSH $expected"; else fail "SSH expected: $expected"; fi
done

for tool in docker age rclone curl gzip; do command_exists "$tool"; done

if systemctl is-active --quiet docker; then pass "Docker service active"; else fail "Docker service inactive"; fi
if systemctl is-active --quiet cloudflared; then pass "cloudflared active"; else fail "cloudflared inactive"; fi

if [ -d "$stack_dir" ]; then
  pass "Supabase stack directory exists"
else
  fail "Supabase stack directory missing: $stack_dir"
fi

compose_files=(
  --env-file "$stack_dir/.env"
  -f "$stack_dir/docker-compose.yml"
  -f "$stack_dir/docker-compose.staging.yml"
)
if [ -f "$stack_dir/docker-compose.studio-ssh.yml" ]; then
  compose_files+=( -f "$stack_dir/docker-compose.studio-ssh.yml" )
fi

if docker compose "${compose_files[@]}" config --quiet; then pass "Compose config valid"; else fail "Compose config invalid"; fi
docker compose "${compose_files[@]}" ps

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
    fail "$container state=${state:-missing}"
  fi
done

if ss -lnt | grep -qE '127\.0\.0\.1:8000[[:space:]]'; then pass "Kong HTTP bound to loopback"; else fail "Kong loopback port 8000 missing"; fi
if ss -lnt | grep -qE '(^|[[:space:]])0\.0\.0\.0:(5432|6543|8000|8443)[[:space:]]'; then
  fail "Database or Kong port exposed on all IPv4 interfaces"
else
  pass "Database and Kong not exposed on all IPv4 interfaces"
fi

if curl -fsS https://supabase-staging.rinkissaupigiausia.online/auth/v1/.well-known/jwks.json | grep -q '"keys"'; then
  pass "Public VPS JWKS reachable"
else
  fail "Public VPS JWKS unavailable"
fi

psql_cmd=(docker exec supabase-db psql -v ON_ERROR_STOP=1 -At -U postgres -d postgres)
if "${psql_cmd[@]}" -c 'select 1' | grep -qx '1'; then pass "Postgres query works"; else fail "Postgres query failed"; fi

db_size="$("${psql_cmd[@]}" -c "select pg_size_pretty(pg_database_size(current_database()));" 2>/dev/null || true)"
info "database_size=${db_size:-unknown}"

refresh="$("${psql_cmd[@]}" -c "select requested_version||'|'||completed_version||'|'||last_status||'|'||coalesce(last_error,'') from public.catalog_read_model_refresh_state;" 2>/dev/null || true)"
info "refresh_state=${refresh:-missing}"
if printf '%s' "$refresh" | awk -F'|' 'NF >= 3 && $1 == $2 && ($3 == "refreshed" || $3 == "clean") && $4 == "" { found=1 } END { exit !found }'; then
  pass "Read model refresh current"
else
  fail "Read model refresh not current"
fi

cron_count="$("${psql_cmd[@]}" -c "select count(*) from cron.job where active and jobname like 'catalog-read-model-refresh%';" 2>/dev/null || true)"
if [ "$cron_count" = "2" ]; then pass "Expected two refresh cron jobs active"; else fail "Refresh cron active count=${cron_count:-unknown}"; fi

if [ -f "$r2_env" ]; then
  mode_owner="$(stat -c '%a %U:%G' "$r2_env")"
  if [ "$mode_owner" = "600 root:root" ]; then pass "R2 secret permissions 600 root:root"; else fail "R2 secret permissions=$mode_owner"; fi
  key_count="$(awk -F= '$1 ~ /^R2_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|ENDPOINT|BUCKET|REGION)$/ {count++} END {print count+0}' "$r2_env")"
  if [ "$key_count" = "5" ]; then pass "R2 secret contains expected variable names"; else fail "R2 secret expected variable count=5 actual=$key_count"; fi
else
  fail "R2 secret file missing: $r2_env"
fi

backup_units="$(systemctl list-unit-files --no-legend 2>/dev/null | grep -Ei '(aboutyou|supabase).*backup|backup.*(aboutyou|supabase)' || true)"
if [ -n "$backup_units" ]; then
  pass "Backup systemd unit found"
  printf '%s\n' "$backup_units"
else
  fail "No Supabase backup systemd unit found"
fi

latest_backup="$(find /srv/supabase/backups -maxdepth 3 -type f -printf '%T@ %TY-%Tm-%TdT%TH:%TM:%TSZ %s %p\n' 2>/dev/null | sort -nr | head -n 1 || true)"
info "latest_local_backup=${latest_backup:-none}"

if [ "$failed" -gt 0 ]; then
  printf '\nSummary: %s failed checks\n' "$failed" >&2
  exit 1
fi

printf '\nSummary: all VPS readiness checks passed\n'
