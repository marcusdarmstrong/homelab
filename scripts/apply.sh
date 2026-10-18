#!/usr/bin/env bash
# Converge this host to the checked-out commit and the profiles in .env.
#
# `up --remove-orphans` handles services deleted from the compose files, but
# not services whose profile was switched off, since those are still defined.
# They get stopped explicitly below.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

cd "$REPO_DIR"
# COMPOSE_ENV_FILES lets test/smoke.sh supply its own env.
[[ -f .env || -n "${COMPOSE_ENV_FILES:-}" ]] || die "missing $REPO_DIR/.env (copy .env.example and fill it in)"
load_host_env
placeholders="$(placeholder_keys)"
[[ -z "$placeholders" ]] || die "placeholder values in .env: $placeholders"

# Compose interpolates every service whether or not its profile is active, so
# profile-specific secrets can't use ${VAR:?}. Check them here instead.
declare -A required_by_profile=(
  [observability]="NTFY_GRAFANA_TOKEN NTFY_GRAFANA_PASSWORD_HASH"
  [backup]="RESTIC_REPOSITORY RESTIC_PASSWORD"
  [unifi]="UNIFI_URL UNIFI_API_KEY"
)
# Only obtainable after the first deploy (they come from Pocket ID), so
# missing ones are reported but don't block.
declare -A oidc_by_profile=(
  [always]="TINYAUTH_OIDC_CLIENT_ID TINYAUTH_OIDC_CLIENT_SECRET"
  [observability]="GRAFANA_OIDC_CLIENT_ID GRAFANA_OIDC_CLIENT_SECRET"
)

profiles="$(env_get COMPOSE_PROFILES)"
IFS=',' read -ra active <<<"$profiles"
for profile in always "${active[@]}"; do
  for var in ${required_by_profile[$profile]:-}; do
    [[ -n "$(env_get "$var")" ]] || die "profile '$profile' requires $var in .env"
  done
  for var in ${oidc_by_profile[$profile]:-}; do
    [[ -n "$(env_get "$var")" ]] || log "warning: $var is unset; SSO for that app won't work until it is (see README)"
  done
done

# Compose doesn't recreate a container when a bind-mounted config file
# changes, and since git replaces files rather than editing them, single-file
# mounts would keep serving the old copy. Each stacks/<stack>/<dir>/ gets a
# content hash in CONFIG_HASH_<STACK>_<DIR>, which the service using it
# carries as a label, so a changed file forces a recreate.
config_hash() { find "$1" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16; }
for dir in stacks/*/*/; do
  name="$(basename "$(dirname "$dir")")_$(basename "$dir")"
  export "CONFIG_HASH_$(tr '[:lower:]-' '[:upper:]_' <<<"$name")=$(config_hash "$dir")"
done

log "profiles: ${profiles:-<none>}"
# --wait: only succeed once every container is running (healthy, where it has
# a healthcheck), so a crash-looping service fails the deploy.
# HOMELAB_FORCE_RECREATE: bootstrap sets it when a daemon-level setting that's
# fixed at container creation (the log driver) changed.
docker compose up -d --remove-orphans --wait --wait-timeout "${HOMELAB_WAIT_TIMEOUT:-300}" \
  ${HOMELAB_FORCE_RECREATE:+--force-recreate}

project=homelab # `name:` in compose.yaml
enabled="$(docker compose config --services | sort)"
running="$(docker ps -a --filter "label=com.docker.compose.project=$project" \
             --format '{{.Label "com.docker.compose.service"}}' | sort -u)"
disabled="$(comm -13 <(echo "$enabled") <(echo "$running"))"
if [[ -n "$disabled" ]]; then
  log "stopping services with disabled profiles: $(echo "$disabled" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  COMPOSE_PROFILES='*' docker compose rm --stop --force $disabled
fi

# Only some services have healthchecks, and a container that crashes a second
# after starting still looks "running" to --wait. Watch for a while and fail
# if anything stops or restarts.
container_states() {
  docker ps -aq --filter "label=com.docker.compose.project=$project" |
    xargs docker inspect -f '{{.Name}} {{.RestartCount}} {{.State.Status}}'
}
before="$(container_states)"
sleep "${HOMELAB_SETTLE_SECONDS:-30}"
unstable="$(awk 'NR == FNR { restarts[$1] = $2; next }
                 $3 != "running" || $2 != restarts[$1] { print substr($1, 2) }' \
              <(echo "$before") <(container_states))"
[[ -z "$unstable" ]] || die "not staying up: $(echo "$unstable" | tr '\n' ' ')"

docker image prune -f >/dev/null
log "converged"
