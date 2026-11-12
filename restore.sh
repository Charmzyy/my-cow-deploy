#!/usr/bin/env bash
# Restore a backup made by backup.sh.
#
#   ./restore.sh db backups/db-nightly-2026-11-20-0200.sql.gz restore_test
#        load into a SCRATCH database (safe; use it to prove backups work)
#   ./restore.sh db backups/db-nightly-2026-11-20-0200.sql.gz cowbreed --yes
#        overwrite the LIVE database (stops the app while loading)
#   ./restore.sh uploads backups/uploads-2026-11-20-0200.tar.gz --yes
#        replace the uploaded photos
#
# Off-server copies: rclone copy r2:mycow-backups/<file> backups/   first.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

die() { echo "restore: $*" >&2; exit 1; }
what=${1:-}; file=${2:-}
[[ -f "$file" ]] || die "file not found: $file"
live=$(grep -E '^DB_DATABASE=' .env | cut -d= -f2-)

case "$what" in
  db)
    target=${3:-}
    [[ "$target" =~ ^[A-Za-z0-9_]+$ ]] || die "give a database name (letters, digits, _)"
    if [[ "$target" == "$live" ]]; then
      [[ "${4:-}" == --yes ]] || die "that is the LIVE database; add --yes if you mean it"
      docker compose stop app
    fi
    docker compose exec -T mysql sh -c "exec mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e 'CREATE DATABASE IF NOT EXISTS \`$target\`'"
    gzip -cd "$file" | docker compose exec -T mysql sh -c "exec mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"$target\""
    [[ "$target" == "$live" ]] && docker compose start app
    echo "restore: $file -> database $target. Row counts:"
    docker compose exec -T mysql sh -c "exec mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='$target' ORDER BY table_name\""
    ;;
  uploads)
    [[ "${3:-}" == --yes ]] || die "this replaces every uploaded photo; add --yes if you mean it"
    docker run --rm -v mycow_uploads:/data -v "$(readlink -f "$file")":/backup.tar.gz:ro alpine \
      sh -c 'find /data -mindepth 1 -delete && tar xzf /backup.tar.gz -C /data && chown -R 33:33 /data'
    echo "restore: photos restored from $file"
    ;;
  *) die "usage: restore.sh db <file> <database> [--yes] | restore.sh uploads <file> --yes" ;;
esac
