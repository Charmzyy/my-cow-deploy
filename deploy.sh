#!/usr/bin/env bash
# Deploy one service at one tag, check it, and roll back by itself if the check fails.
#
#   ./deploy.sh rest v15      (Laravel API: also backs up the DB first and runs migrations)
#   ./deploy.sh client v15    (Vue app)
#   ./deploy.sh py v4         (breed model)
#
# GitHub Actions calls this over SSH with a deploy key that may run NOTHING else
# (authorized_keys: restrict,command="/srv/mycow/deploy.sh" ...). In that case the arguments
# arrive in $SSH_ORIGINAL_COMMAND and are checked strictly below.
#
# A rollback swaps the IMAGE back; it does not undo migrations. Keep migrations additive
# (new tables / nullable columns), and use the pre-deploy dump in backups/ if one must be undone.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

die() { echo "deploy: $*" >&2; exit 1; }

# --- Arguments: from the command line, or from the forced SSH command -------------------------
if [[ $# -eq 0 && -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
  if [[ "$SSH_ORIGINAL_COMMAND" =~ deploy\.sh[[:space:]]+(rest|client|py)[[:space:]]+(v[0-9]+(\.[0-9]+)*) ]]; then
    set -- "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    die "refused: expected 'deploy.sh <rest|client|py> <vN>'"
  fi
fi

target=${1:-}
tag=${2:-}
case "$target" in
  rest)   var=REST_TAG;   service=app ;;
  client) var=CLIENT_TAG; service=client ;;
  py)     var=PY_TAG;     service=model ;;
  *) die "usage: deploy.sh <rest|client|py> <vN>" ;;
esac
[[ "$tag" =~ ^v[0-9]+(\.[0-9]+)*$ ]] || die "tag must look like v15 or v15.1, got '$tag'"

# Three repos can be tagged at once: deploy one at a time
exec 9>/tmp/mycow-deploy.lock
flock -w 900 9 || die "another deploy is still running"

[[ -f .env ]] || die ".env missing in $(pwd)"
domain=$(grep -E '^DOMAIN=' .env | cut -d= -f2- || true)
old=$(grep -E "^${var}=" .env | cut -d= -f2- || true)
[[ -n "$domain" ]] || die "DOMAIN not set in .env"
[[ -n "$old" ]] || die "$var not set in .env"

set_tag() { sed -i "s/^${var}=.*/${var}=$1/" .env; }

# Waits (up to ~4 min: TensorFlow loads slowly) until the container reports healthy
# AND the public site answers /api/health
healthy() {
  local id status
  for _ in $(seq 1 80); do
    id=$(docker compose ps -q "$service")
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$id" 2>/dev/null || echo missing)
    if [[ "$status" == healthy || "$status" == running ]] && curl -fsS --max-time 5 "https://${domain}/api/health" >/dev/null; then
      return 0
    fi
    sleep 3
  done
  echo "deploy: $service never became healthy (last status: ${status:-unknown})" >&2
  docker compose logs --tail 60 "$service" >&2 || true
  return 1
}

rollback() {
  echo "deploy: ROLLING BACK $service to $old" >&2
  set_tag "$old"
  docker compose up -d "$service"
  healthy || echo "deploy: rollback is unhealthy too: look at the server now" >&2
  exit 1
}

echo "deploy: $service $old -> $tag ($(date -Is))"
if [[ "$old" == "$tag" ]]; then
  echo "deploy: already on $tag, re-pulling anyway"
fi

[[ "$target" == rest ]] && ./backup.sh pre-deploy

set_tag "$tag"
docker compose pull "$service" || { set_tag "$old"; die "could not pull ${service}:${tag} (is the image published for this CPU?)"; }
docker compose up -d "$service"

healthy || rollback
if [[ "$target" == rest ]]; then
  docker compose exec -T app php artisan migrate --force || rollback
  healthy || rollback
fi

docker image prune -f >/dev/null   # drop the old, now-untagged layers so the disk doesn't fill
echo "deploy: $service is live on $tag"
