#!/usr/bin/env bash
# Back up the database (and, nightly, the uploaded photos) to backups/ and to off-server storage.
#
#   ./backup.sh             nightly: DB + photos, copy to $BACKUP_REMOTE, keep 7 days here, 30 days there
#   ./backup.sh pre-deploy  DB only, kept here (last 5); deploy.sh runs this before every API release
#
# cron (crontab -e as the deploy user):
#   0 2 * * * /srv/mycow/backup.sh >> /srv/mycow/backups/backup.log 2>&1
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

mode=${1:-nightly}
dir=backups
mkdir -p "$dir"
stamp=$(date +%F-%H%M)
remote=$(grep -E '^BACKUP_REMOTE=' .env | cut -d= -f2- || true)

# The dump runs INSIDE the mysql container, using its own env vars, so the password never
# appears on this machine's command line. --single-transaction = consistent without locking.
db="$dir/db-${mode}-${stamp}.sql.gz"
docker compose exec -T mysql sh -c \
  'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers --no-tablespaces "$MYSQL_DATABASE"' \
  | gzip > "$db"
# A failed dump can still leave a tiny gzip behind: refuse to call that a backup
[[ $(gzip -cd "$db" | head -c 200000 | grep -c 'CREATE TABLE') -gt 0 ]] || { rm -f "$db"; echo "backup: dump looks empty" >&2; exit 1; }
echo "backup: $db ($(du -h "$db" | cut -f1))"

if [[ "$mode" == pre-deploy ]]; then
  ls -1t "$dir"/db-pre-deploy-*.sql.gz | tail -n +6 | xargs -r rm -f
  exit 0
fi

# Photos: tar the uploads volume read-only from a throwaway container
docker run --rm -v mycow_uploads:/data:ro -v "$(pwd)/$dir":/backup alpine \
  tar czf "/backup/uploads-${stamp}.tar.gz" -C /data .
echo "backup: $dir/uploads-${stamp}.tar.gz"

if [[ -n "$remote" ]]; then
  rclone copy "$dir" "$remote" --include "db-nightly-${stamp}.sql.gz" --include "uploads-${stamp}.tar.gz"
  rclone delete "$remote" --min-age 30d
  echo "backup: copied to $remote"
else
  echo "backup: BACKUP_REMOTE not set, this backup exists only on this server" >&2
fi

find "$dir" -name 'db-nightly-*.sql.gz' -mtime +7 -delete
find "$dir" -name 'uploads-*.tar.gz' -mtime +7 -delete
