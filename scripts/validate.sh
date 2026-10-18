#!/usr/bin/env bash
# Static checks for the repo; run locally or in CI. Needs docker (config
# linters run from the same images that are deployed).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"
cd "$REPO_DIR"

image_of() { grep -hoE "image: *\S*$1:\S+" stacks/*/compose.yaml | head -1 | awk '{print $2}'; }
obs=stacks/observability

log "compose config (all profiles)"
COMPOSE_PROFILES='*' docker compose --env-file .env.example config --quiet

log "prometheus config"
docker run --rm --entrypoint promtool -v "$PWD/$obs/prometheus:/cfg:ro" \
  "$(image_of prometheus)" check config /cfg/prometheus.yml

log "loki config"
docker run --rm -v "$PWD/$obs/loki:/cfg:ro" \
  "$(image_of loki)" -config.file=/cfg/loki.yaml -config.expand-env=true -verify-config

log "alloy config"
docker run --rm -v "$PWD/$obs/alloy:/cfg:ro" \
  "$(image_of alloy)" fmt /cfg/config.alloy | diff -u "$obs/alloy/config.alloy" - ||
  die "config.alloy isn't in canonical format (alloy fmt)"

log "smartctl-exporter image builds"
docker build --quiet stacks/smart >/dev/null

log "shellcheck"
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh

log "all checks passed"
