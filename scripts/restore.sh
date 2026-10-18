#!/usr/bin/env bash
# Restore Docker volumes from this host's latest restic snapshot.
#
#   restore.sh                  every volume in the snapshot
#   restore.sh pocket-id-data   just the named volume(s), without `homelab_`
#
# Rebuilding a host: bootstrap.sh, let the first deploy create the volumes,
# then run this. The project is stopped during the restore and started again
# afterwards.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"
cd "$REPO_DIR"

load_host_env

export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
RESTIC_REPOSITORY="$(env_get RESTIC_REPOSITORY)"
RESTIC_PASSWORD="$(env_get RESTIC_PASSWORD)"
AWS_ACCESS_KEY_ID="$(env_get RESTIC_S3_ACCESS_KEY_ID)"
AWS_SECRET_ACCESS_KEY="$(env_get RESTIC_S3_SECRET_ACCESS_KEY)"
[[ -n "$RESTIC_REPOSITORY" && -n "$RESTIC_PASSWORD" ]] || die "RESTIC_REPOSITORY and RESTIC_PASSWORD must be set in .env"

host="$(env_get HOST_NAME)"
image="$(grep -oE 'mazzolino/restic:\S+' stacks/backup/compose.yaml)"

includes=()
for volume in "$@"; do
  includes+=(--include "/source/homelab_$volume")
done

restic() {
  docker run --rm -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    -v /var/lib/docker/volumes:/source --entrypoint restic "$image" "$@"
}

restic snapshots --host "$host" --latest 1

log "stopping the project"
docker compose stop

log "restoring ${*:-all volumes}"
restic restore latest --host "$host" --target / "${includes[@]}"

log "starting the project"
"$REPO_DIR/scripts/apply.sh"
