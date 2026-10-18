# shellcheck shell=bash
# Shared helpers for the homelab scripts. Sourced, not executed.

log() { printf '[homelab] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

HOMELAB_BRANCH="${HOMELAB_BRANCH:-main}"
