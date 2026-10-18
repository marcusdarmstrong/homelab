# shellcheck shell=bash
# Shared helpers for the homelab scripts. Sourced, not executed.

# bootstrap.sh defines its own before the checkout (and so this file) exists.
declare -F log >/dev/null || log() { printf '[homelab] %s\n' "$*" >&2; }
declare -F die >/dev/null || die() { log "error: $*"; exit 1; }

HOMELAB_BRANCH="${HOMELAB_BRANCH:-main}"

# Point every later `docker compose` call at the host's env: .env (or the
# caller's COMPOSE_ENV_FILES, as the tests do), layered over
# config/sdcard.env when it declares HOST_STORAGE=sdcard. Run from the repo.
use_host_env() {
  local base="${COMPOSE_ENV_FILES:-.env}" storage
  storage="$(COMPOSE_ENV_FILES="$base" docker compose config --environment | sed -n 's/^HOST_STORAGE=//p')"
  case "${storage:-ssd}" in
    ssd) export COMPOSE_ENV_FILES="$base" ;;
    sdcard) export COMPOSE_ENV_FILES="config/sdcard.env,$base" ;;
    *) die "HOST_STORAGE must be ssd or sdcard, not '$storage'" ;;
  esac
}

# use_host_env, then keep the environment as compose resolves it (not by
# sourcing .env as shell) in HOST_ENV for env_get and placeholder_keys.
load_host_env() {
  use_host_env
  HOST_ENV="$(docker compose config --environment)"
}
env_get() { sed -n "s/^$1=//p" <<<"$HOST_ENV"; }

# Everything bootstrap.sh's result depends on. sync.sh re-runs it whenever
# this differs from what its last successful run recorded. Run from the repo.
host_config_hash() { cat scripts/bootstrap.sh scripts/lib.sh systemd/* config/sdcard.env .env | sha256sum | cut -d' ' -f1; }
# shellcheck disable=SC2034  # used by bootstrap.sh and sync.sh
BOOTSTRAP_STATE="${HOMELAB_STATE_DIR:-/var/lib/homelab}/bootstrapped"

# Keys still holding a placeholder from .env.example (changeme,
# CHANGE-ME, changeme-at-least-16-chars), space-separated.
placeholder_keys() { grep -iE '^[A-Za-z0-9_]+=change-?me' <<<"$HOST_ENV" | cut -d= -f1 | paste -sd' ' - || true; }
