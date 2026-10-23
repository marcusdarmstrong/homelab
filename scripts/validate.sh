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

# Committed settings files: everything in hosts/ and config/ that git would
# track. (Your own secrets files are gitignored.)
committed=()
for f in hosts/*.env config/*.env; do
  git check-ignore -q "$f" || committed+=("$f")
done

log "no secrets in committed settings (the repo is public)"
leaks="$(grep -HE '^[A-Z0-9_]*(SECRET|PASSWORD|TOKEN|KEY|HASH|EMAIL)[A-Z0-9_]*=' "${committed[@]}" | cut -d= -f1 || true)"
[[ -z "$leaks" ]] || die "secret-looking settings belong in hosts/secrets.env: $(echo "$leaks" | tr '\n' ' ')"

# Every host's real settings, with the example secrets standing in for its own.
hosts=()
for f in "${committed[@]}"; do
  [[ "$f" == hosts/* && "$f" != hosts/common.env ]] && hosts+=("$(basename "$f" .env)")
done
((${#hosts[@]})) || die "no hosts/<name>.env"
secrets="$(mktemp)"
summary="$(mktemp)"
trap 'rm -f "$secrets" "$summary"' EXIT
for name in "${hosts[@]}"; do
  log "compose config: $name (its profiles, then all of them)"
  { echo "HOST_NAME=$name"; cat hosts/secrets.env.example; } >"$secrets"
  (
    export COMPOSE_ENV_FILES
    COMPOSE_ENV_FILES="$(host_env_files "$name" "$secrets")"
    load_host_env
    docker compose config --quiet
    COMPOSE_PROFILES='*' docker compose config --quiet
    echo "$name $(env_get SITE) ,$(env_get COMPOSE_PROFILES),"
  ) >>"$summary"
done

log "services that run once are on exactly one host"
for profile in sso observability; do
  on="$(awk -v p=",$profile," 'index($3, p) { print $1 }' "$summary" | paste -sd' ' -)"
  [[ "$(wc -w <<<"$on")" -eq 1 ]] || die "exactly one host must run $profile (now: ${on:-none})"
done
on="$(awk 'index($3, ",unifi,") { print $2 }' "$summary" | sort | uniq -d)"
[[ -z "$on" ]] || die "more than one host runs unifi at: $on"

# Every sdcard setting must be read somewhere, or it silently does nothing.
sed -n 's/^\([A-Z0-9_]*\)=.*/\1/p' config/sdcard.env | while read -r key; do
  git grep -q "$key" -- stacks scripts/bootstrap.sh || die "config/sdcard.env: $key isn't used anywhere"
done

log "prometheus config"
docker run --rm --entrypoint promtool -v "$PWD/$obs/prometheus:/cfg:ro" \
  "$(image_of prometheus)" check config /cfg/prometheus.yml

log "loki config"
docker run --rm -v "$PWD/$obs/loki:/cfg:ro" \
  "$(image_of loki)" -config.file=/cfg/loki.yaml -config.expand-env=true -verify-config

log "alloy config"
docker run --rm -v "$PWD/stacks/alloy/config:/cfg:ro" \
  "$(image_of alloy)" fmt /cfg/config.alloy | diff -u stacks/alloy/config/config.alloy - ||
  die "config.alloy isn't in canonical format (alloy fmt)"

log "smartctl-exporter image builds"
docker build --quiet stacks/smart >/dev/null

log "shellcheck"
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh stacks/*/*/*.sh

log "all checks passed"
