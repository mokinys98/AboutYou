#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo bash verify-vps-backup-restore.sh" >&2
  exit 2
fi

for tool in docker age rclone tar sha256sum awk sort find du date; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

r2_env="/etc/aboutyou-backup/r2.env"
identity_file="/etc/aboutyou-backup/age-identity"
backup_root="/srv/supabase/backups"

if [ ! -f "$r2_env" ]; then
  echo "Missing $r2_env" >&2
  exit 1
fi
if [ ! -f "$identity_file" ]; then
  echo "Missing $identity_file" >&2
  exit 1
fi
if [ "$(stat -c '%a' "$identity_file")" != "600" ]; then
  echo "$identity_file must have mode 600" >&2
  exit 1
fi

set -a
. "$r2_env"
set +a

required=(R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET)
for name in "${required[@]}"; do
  if [ -z "${!name:-}" ]; then
    echo "Missing required variable: $name" >&2
    exit 1
  fi
done

export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
export RCLONE_CONFIG_R2_REGION=auto
export RCLONE_CONFIG_R2_ACL=private
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

started_at="$(date +%s)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
work_dir="$(mktemp -d "$backup_root/disposable-restore-${timestamp}-XXXXXX")"
container="aboutyou-restore-${timestamp,,}"
container="${container//[^a-z0-9_.-]/-}"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

remote_object="${1:-}"
if [ -z "$remote_object" ]; then
  echo "Selecting the newest automatic backup from R2"
  remote_object="$(
    rclone lsf --recursive --files-only --format 'tp' --separator ';' "R2:${R2_BUCKET}/automatic" |
      awk '$0 ~ /aboutyou-supabase-[0-9TZ]+\.tar\.age$/ {print}' |
      sort |
      tail -n 1 |
      sed -E 's/^[^;]*;//'
  )"
  if [ -n "$remote_object" ]; then
    remote_object="automatic/${remote_object}"
  fi
fi
if [ -z "$remote_object" ]; then
  echo "No encrypted automatic backup found in R2" >&2
  exit 1
fi

encrypted_file="$work_dir/backup.tar.age"
payload_tar="$work_dir/payload.tar"
payload_dir="$work_dir/payload"
storage_dir="$work_dir/storage-files"
custom_dir="$work_dir/postgresql-custom"
data_dir="$work_dir/postgres-data"
env_file="$work_dir/container.env"
role_settings_file="$work_dir/role-settings.sql"

echo "Downloading encrypted backup from R2: $remote_object"
rclone copyto --no-check-dest "R2:${R2_BUCKET}/${remote_object}" "$encrypted_file"

echo "Decrypting backup"
age --decrypt -i "$identity_file" -o "$payload_tar" "$encrypted_file"

install -d -m 0700 "$payload_dir" "$storage_dir" "$custom_dir" "$data_dir"
tar -tf "$payload_tar" >/dev/null
tar -C "$payload_dir" -xf "$payload_tar"

for file in roles.sql database.dump storage-files.tar postgresql-custom.tar metadata.txt SHA256SUMS; do
  if [ ! -f "$payload_dir/$file" ]; then
    echo "Backup payload is missing $file" >&2
    exit 1
  fi
done

echo "Verifying payload checksums"
(
  cd "$payload_dir"
  sha256sum -c SHA256SUMS
)

echo "Extracting Storage bytes and Postgres custom key material"
tar -C "$storage_dir" -xf "$payload_dir/storage-files.tar"
tar -C "$custom_dir" -xf "$payload_dir/postgresql-custom.tar"

image="$(docker inspect --format '{{.Config.Image}}' supabase-db)"
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' supabase-db > "$env_file"

declare -a mount_args=()
while IFS='|' read -r source destination type; do
  if [ "$type" = "bind" ] && [[ "$destination" == /docker-entrypoint-initdb.d/* ]]; then
    mount_args+=(--mount "type=bind,src=$source,dst=$destination,readonly")
  fi
done < <(docker inspect --format '{{range .Mounts}}{{printf "%s|%s|%s\n" .Source .Destination .Type}}{{end}}' supabase-db)

declare -a command_args=()
while IFS= read -r arg; do
  if [ -n "$arg" ]; then
    command_args+=("$arg")
  fi
done < <(docker inspect --format '{{range .Config.Cmd}}{{println .}}{{end}}' supabase-db)

if [ "${#command_args[@]}" -eq 0 ]; then
  echo "Unable to copy the running Supabase Postgres command" >&2
  exit 1
fi

echo "Starting isolated disposable Postgres container from $image"
docker run -d \
  --name "$container" \
  --network none \
  --env-file "$env_file" \
  --mount "type=bind,src=$data_dir,dst=/var/lib/postgresql/data" \
  --mount "type=bind,src=$custom_dir,dst=/etc/postgresql-custom" \
  "${mount_args[@]}" \
  "$image" \
  "${command_args[@]}" >/dev/null

ready=0
for _ in $(seq 1 120); do
  if docker exec "$container" pg_isready -U postgres -d postgres >/dev/null 2>&1; then
    ready=1
    break
  fi
  if [ "$(docker inspect --format '{{.State.Running}}' "$container")" != "true" ]; then
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "Disposable Postgres did not become ready" >&2
  docker logs --tail 100 "$container" >&2 || true
  exit 1
fi

echo "Applying backed-up role settings to roles initialized by the Supabase image"
awk '/^(SET |RESET |ALTER ROLE )/' "$payload_dir/roles.sql" > "$role_settings_file"
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d postgres < "$role_settings_file"

echo "Restoring database dump into disposable container"
docker exec -i "$container" pg_restore \
  --exit-on-error \
  --clean \
  --if-exists \
  --no-owner \
  --no-acl \
  -U postgres \
  -d postgres < "$payload_dir/database.dump"

echo "Running restore smoke queries"
docker exec "$container" psql -v ON_ERROR_STOP=1 -At -U postgres -d postgres -c \
  "SELECT 'products=' || count(*) FROM public.products
   UNION ALL SELECT 'categories=' || count(*) FROM public.categories
   UNION ALL SELECT 'auth_users=' || count(*) FROM auth.users
   UNION ALL SELECT 'storage_objects=' || count(*) FROM storage.objects;"

storage_files="$(find "$storage_dir" -type f | wc -l | tr -d ' ')"
storage_bytes="$(du -sb "$storage_dir" | awk '{print $1}')"
database_bytes="$(docker exec "$container" psql -At -U postgres -d postgres -c 'select pg_database_size(current_database());')"
finished_at="$(date +%s)"
rto_seconds="$((finished_at - started_at))"

echo "RESTORE_VERIFY_SUCCESS rto_seconds=$rto_seconds database_bytes=$database_bytes storage_files=$storage_files storage_bytes=$storage_bytes remote=$remote_object"
