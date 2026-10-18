# shellcheck shell=bash
# Shared helpers for the homelab scripts. Sourced, not executed.

log() { printf '[homelab] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

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
