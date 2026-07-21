#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo bash scripts/migration/install-vps-monitoring.sh" >&2
  exit 2
fi

source_script="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vps-monitor.sh}"
config_dir="/etc/aboutyou-monitor"
config_file="$config_dir/monitor.env"
program="/usr/local/sbin/aboutyou-vps-monitor"
service_file="/etc/systemd/system/aboutyou-vps-monitor.service"
timer_file="/etc/systemd/system/aboutyou-vps-monitor.timer"

for tool in curl docker systemctl awk sed find sort; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 1; }
done
if [ ! -f "$source_script" ]; then
  echo "Monitor source not found: $source_script" >&2
  exit 1
fi

install -d -m 0700 -o root -g root "$config_dir" /var/lib/aboutyou-monitor
install -m 0750 -o root -g root "$source_script" "$program"

if [ ! -f "$config_file" ]; then
  config_tmp="$(mktemp)"
  cat > "$config_tmp" <<'MONITOR_ENV'
DISK_MAX_PERCENT=80
BACKUP_MAX_AGE_SECONDS=129600
SUPABASE_HEALTH_URL=https://supabase-staging.rinkissaupigiausia.online/auth/v1/.well-known/jwks.json
API_HEALTH_URL=https://aboutyou-private-catalog-api-staging.aurimas-zvirb.workers.dev/health
ALERT_WEBHOOK_URL=
MONITOR_ENV
  install -m 0600 -o root -g root "$config_tmp" "$config_file"
  rm -f -- "$config_tmp"
fi

service_tmp="$(mktemp)"
cat > "$service_tmp" <<'SERVICE_UNIT'
[Unit]
Description=AboutYou VPS and Supabase health monitor
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/local/sbin/aboutyou-vps-monitor
TimeoutStartSec=3m
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=/etc/aboutyou-monitor /srv/supabase/backups
ReadWritePaths=/var/lib/aboutyou-monitor
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
SERVICE_UNIT
install -m 0644 -o root -g root "$service_tmp" "$service_file"
rm -f -- "$service_tmp"

timer_tmp="$(mktemp)"
cat > "$timer_tmp" <<'TIMER_UNIT'
[Unit]
Description=Run AboutYou VPS health monitor every five minutes

[Timer]
OnBootSec=2m
OnUnitActiveSec=5m
RandomizedDelaySec=30s
Persistent=true
Unit=aboutyou-vps-monitor.service

[Install]
WantedBy=timers.target
TIMER_UNIT
install -m 0644 -o root -g root "$timer_tmp" "$timer_file"
rm -f -- "$timer_tmp"

systemctl daemon-reload
systemctl enable --now aboutyou-vps-monitor.timer

if systemctl start aboutyou-vps-monitor.service; then
  systemctl --no-pager --full status aboutyou-vps-monitor.service || true
else
  systemctl --no-pager --full status aboutyou-vps-monitor.service || true
  journalctl -u aboutyou-vps-monitor.service -n 100 --no-pager || true
  exit 1
fi

systemctl list-timers aboutyou-vps-monitor.timer --no-pager
if grep -q '^ALERT_WEBHOOK_URL=.' "$config_file"; then
  echo "External alert webhook configured."
else
  echo "Monitoring is active in systemd journal. Optional external delivery can be set in $config_file as ALERT_WEBHOOK_URL."
fi
