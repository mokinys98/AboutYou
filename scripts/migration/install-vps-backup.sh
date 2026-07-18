#!/usr/bin/env bash
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo bash install-vps-backup.sh" >&2
  exit 2
fi

config_dir="/etc/aboutyou-backup"
backup_env="$config_dir/backup.env"
r2_env="$config_dir/r2.env"
backup_program="/usr/local/sbin/aboutyou-supabase-backup"
service_file="/etc/systemd/system/aboutyou-supabase-backup.service"
timer_file="/etc/systemd/system/aboutyou-supabase-backup.timer"

for tool in docker age rclone tar sha256sum flock systemctl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

if [ ! -f "$r2_env" ]; then
  echo "Missing $r2_env" >&2
  exit 1
fi

install -d -m 0700 "$config_dir"
install -d -m 0700 /srv/supabase/backups/encrypted

age_recipient=""
if [ -f "$backup_env" ]; then
  age_recipient="$(awk -F= '$1 == "AGE_RECIPIENT" {print substr($0, index($0, "=") + 1); exit}' "$backup_env")"
fi

if [ -z "$age_recipient" ]; then
  printf 'Enter the public age recipient (starts with age1): '
  IFS= read -r age_recipient
fi

case "$age_recipient" in
  age1*) ;;
  *) echo "Invalid age recipient. Expected a public age1... value." >&2; exit 1 ;;
esac

env_tmp="$(mktemp)"
trap 'rm -f "$env_tmp"' EXIT
printf 'AGE_RECIPIENT=%s\nLOCAL_RETENTION_DAYS=3\nR2_BACKUP_PREFIX=automatic\n' "$age_recipient" > "$env_tmp"
install -m 0600 -o root -g root "$env_tmp" "$backup_env"

program_tmp="$(mktemp)"
cat > "$program_tmp" <<'BACKUP_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

exec 9>/run/lock/aboutyou-supabase-backup.lock
if ! flock -n 9; then
  echo "Another backup is already running"
  exit 0
fi

r2_env="/etc/aboutyou-backup/r2.env"
backup_env="/etc/aboutyou-backup/backup.env"
backup_root="/srv/supabase/backups/encrypted"

set -a
. "$r2_env"
. "$backup_env"
set +a

required=(R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET R2_REGION AGE_RECIPIENT)
for name in "${required[@]}"; do
  if [ -z "${!name:-}" ]; then
    echo "Missing required variable: $name" >&2
    exit 1
  fi
done

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
work_dir="$(mktemp -d "$backup_root/.work-${timestamp}-XXXXXX")"
storage_paused=0
cleanup() {
  if [ "$storage_paused" -eq 1 ]; then
    docker unpause supabase-storage >/dev/null 2>&1 || true
  fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

roles_file="$work_dir/roles.sql"
database_file="$work_dir/database.dump"
storage_file="$work_dir/storage-files.tar"
postgres_custom_file="$work_dir/postgresql-custom.tar"
metadata_file="$work_dir/metadata.txt"
checksums_file="$work_dir/SHA256SUMS"
archive_name="aboutyou-supabase-${timestamp}.tar.age"
encrypted_file="$work_dir/$archive_name"
final_file="$backup_root/$archive_name"
remote_object="${R2_BACKUP_PREFIX:-automatic}/${timestamp}/${archive_name}"

storage_source="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/storage"}}{{.Source}}{{end}}{{end}}' supabase-storage)"
if [ -z "$storage_source" ] || [ ! -d "$storage_source" ]; then
  echo "Unable to resolve the physical Supabase Storage mount" >&2
  exit 1
fi

echo "Pausing Storage writes for a consistent DB and object snapshot"
docker pause supabase-storage >/dev/null
storage_paused=1

echo "Creating roles dump"
docker exec supabase-db pg_dumpall -U postgres --roles-only --no-role-passwords > "$roles_file"

echo "Creating consistent custom-format database dump"
docker exec supabase-db pg_dump -U postgres -d postgres -Fc --no-owner --no-acl > "$database_file"

echo "Archiving physical Storage object bytes"
tar -C "$storage_source" -cf "$storage_file" .

echo "Archiving Postgres custom configuration and pgsodium key material"
docker exec supabase-db tar -C /etc/postgresql-custom -cf - . > "$postgres_custom_file"

docker unpause supabase-storage >/dev/null
storage_paused=0

{
  printf 'created_at_utc=%s\n' "$timestamp"
  printf 'host=%s\n' "$(hostname)"
  printf 'postgres_version='
  docker exec supabase-db psql -At -U postgres -d postgres -c 'show server_version;'
  printf 'database_size_bytes='
  docker exec supabase-db psql -At -U postgres -d postgres -c 'select pg_database_size(current_database());'
  printf 'source_container_image='
  docker inspect --format '{{.Config.Image}}' supabase-db
  printf 'storage_source=%s\n' "$storage_source"
} > "$metadata_file"

(
  cd "$work_dir"
  sha256sum roles.sql database.dump storage-files.tar postgresql-custom.tar metadata.txt > SHA256SUMS
  tar -cf payload.tar roles.sql database.dump storage-files.tar postgresql-custom.tar metadata.txt SHA256SUMS
)

echo "Encrypting backup for the configured public age recipient"
age -r "$AGE_RECIPIENT" -o "$encrypted_file" "$work_dir/payload.tar"
rm -f -- "$work_dir/payload.tar" "$roles_file" "$database_file" "$storage_file" "$postgres_custom_file" "$metadata_file" "$checksums_file"

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Other
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
export RCLONE_CONFIG_R2_REGION="$R2_REGION"
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

echo "Uploading encrypted backup to R2"
rclone copyto --no-check-dest "$encrypted_file" "R2:${R2_BUCKET}/${remote_object}"

local_size="$(stat -c '%s' "$encrypted_file")"
remote_size="$(rclone lsl "R2:${R2_BUCKET}/${remote_object}" | awk 'NR == 1 {print $1}')"
if [ "$local_size" != "$remote_size" ]; then
  echo "R2 size verification failed: local=$local_size remote=${remote_size:-missing}" >&2
  exit 1
fi

mv -- "$encrypted_file" "$final_file"
sha256="$(sha256sum "$final_file" | awk '{print $1}')"
find "$backup_root" -maxdepth 1 -type f -name 'aboutyou-supabase-*.tar.age' -mtime "+${LOCAL_RETENTION_DAYS:-3}" -delete

echo "Backup completed: file=$final_file bytes=$local_size sha256=$sha256 remote=$remote_object"
BACKUP_SCRIPT
install -m 0750 -o root -g root "$program_tmp" "$backup_program"
rm -f "$program_tmp"

service_tmp="$(mktemp)"
cat > "$service_tmp" <<'SERVICE_UNIT'
[Unit]
Description=Encrypted AboutYou Supabase backup to Cloudflare R2
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/local/sbin/aboutyou-supabase-backup
TimeoutStartSec=2h
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=/etc/aboutyou-backup
ReadWritePaths=/srv/supabase/backups /run/lock
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
SERVICE_UNIT
install -m 0644 -o root -g root "$service_tmp" "$service_file"
rm -f "$service_tmp"

timer_tmp="$(mktemp)"
cat > "$timer_tmp" <<'TIMER_UNIT'
[Unit]
Description=Daily encrypted AboutYou Supabase backup

[Timer]
OnCalendar=*-*-* 02:15:00 UTC
RandomizedDelaySec=15m
Persistent=true
Unit=aboutyou-supabase-backup.service

[Install]
WantedBy=timers.target
TIMER_UNIT
install -m 0644 -o root -g root "$timer_tmp" "$timer_file"
rm -f "$timer_tmp"

systemctl daemon-reload
systemctl enable --now aboutyou-supabase-backup.timer
systemctl list-timers aboutyou-supabase-backup.timer --no-pager

printf 'Run the first encrypted backup now? [Y/n] '
IFS= read -r run_now
case "${run_now:-Y}" in
  n|N|no|NO) echo "Timer installed; first backup was not started." ;;
  *)
    systemctl start aboutyou-supabase-backup.service
    systemctl --no-pager --full status aboutyou-supabase-backup.service || true
    ;;
esac
