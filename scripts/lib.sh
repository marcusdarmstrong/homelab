# shellcheck shell=bash
# Shared helpers for the homelab scripts. Sourced, not executed.

# bootstrap.sh defines its own before the checkout (and so this file) exists.
declare -F log >/dev/null || log() { printf '[homelab] %s\n' "$*" >&2; }
declare -F die >/dev/null || die() { log "error: $*"; exit 1; }

HOMELAB_BRANCH="${HOMELAB_BRANCH:-main}"

# A host's config is layered from these files, later ones winning:
#
#   config/sdcard.env      when the host declares HOST_STORAGE=sdcard
#   hosts/common.env       settings every host shares (committed)
#   hosts/<HOST_NAME>.env  this host's settings (committed)
#   .env                   HOST_NAME and the secrets (on the host only)
#
# local_host_name: HOST_NAME from the host's .env. Run from the repo.
local_host_name() { sed -n 's/^HOST_NAME=//p' .env 2>/dev/null; }

# host_env_files NAME LOCAL_ENV: the committed files for NAME plus LOCAL_ENV,
# comma-separated for COMPOSE_ENV_FILES.
host_env_files() {
  [[ -f "hosts/$1.env" ]] || die "no hosts/$1.env in this checkout"
  echo "hosts/common.env,hosts/$1.env,$2"
}

# Point every later `docker compose` call at the host's env: the files above
# (or the caller's COMPOSE_ENV_FILES, as the tests do), with config/sdcard.env
# underneath when they declare HOST_STORAGE=sdcard. Run from the repo.
use_host_env() {
  local base="${COMPOSE_ENV_FILES:-}" name storage
  if [[ -z "$base" ]]; then
    name="$(local_host_name)"
    [[ -n "$name" ]] || die "no HOST_NAME in $PWD/.env"
    base="$(host_env_files "$name" .env)"
  fi
  storage="$(COMPOSE_ENV_FILES="$base" docker compose config --environment | sed -n 's/^HOST_STORAGE=//p')"
  case "${storage:-ssd}" in
    ssd) export COMPOSE_ENV_FILES="$base" ;;
    sdcard) export COMPOSE_ENV_FILES="config/sdcard.env,$base" ;;
    *) die "HOST_STORAGE must be ssd or sdcard, not '$storage'" ;;
  esac
}

# use_host_env, then keep the environment as compose resolves it (not by
# sourcing the files as shell) in HOST_ENV for env_get and placeholder_keys.
load_host_env() {
  use_host_env
  HOST_ENV="$(docker compose config --environment)"
}
env_get() { sed -n "s/^$1=//p" <<<"$HOST_ENV"; }

# Everything bootstrap.sh's result depends on. sync.sh re-runs it whenever
# this differs from what its last successful run recorded. Run from the repo.
host_config_hash() {
  cat scripts/bootstrap.sh scripts/lib.sh systemd/* config/sdcard.env \
    hosts/common.env "hosts/$(local_host_name).env" .env | sha256sum | cut -d' ' -f1
}
# shellcheck disable=SC2034  # used by bootstrap.sh and sync.sh
BOOTSTRAP_STATE="${HOMELAB_STATE_DIR:-/var/lib/homelab}/bootstrapped"

# Reboots that host-level settings need. bootstrap.sh writes why to
# REBOOT_REQUIRED (the "Reboot pending" alert watches it), and REBOOT_NOW when
# the deploy should do it: sync.sh reboots once a deploy succeeds. Both are in
# /run, so a reboot clears them. REBOOTED_FOR records the settings and reasons
# of the last such reboot, so one that didn't help isn't repeated.
# shellcheck disable=SC2034  # used by bootstrap.sh and sync.sh
REBOOT_REQUIRED=/run/homelab/reboot-required
# shellcheck disable=SC2034
REBOOT_NOW=/run/homelab/reboot-now
# shellcheck disable=SC2034
REBOOTED_FOR="${HOMELAB_STATE_DIR:-/var/lib/homelab}/rebooted-for"

# Keys still holding a placeholder from hosts/secrets.env.example (changeme,
# changeme-at-least-16-chars, changeme@example.com, <account-id>),
# space-separated.
placeholder_keys() { grep -iE '^[A-Za-z0-9_]+=(change-?me|.*<[a-z-]+>)' <<<"$HOST_ENV" | cut -d= -f1 | paste -sd' ' - || true; }

# ---- provision.sh and push-env.sh (run from your checkout) ----------------------

# load_host_file NAME: assemble NAME's .env from your secrets (hosts/secrets.env,
# plus hosts/NAME.secrets.env if there is one) into a temp file, check it
# against the committed host files (valid compose config, no placeholders),
# and load it as load_host_env does. Sets env_file (the assembled .env) and
# target (HOST_SSH, default NAME.local).
load_host_file() {
  local name="$1" placeholders
  [[ -f hosts/secrets.env ]] || die "no hosts/secrets.env (start from hosts/secrets.env.example and scripts/gen-secrets.sh)"
  # The host reads its settings from git, so what's here must be what it gets.
  git fetch --quiet origin "$HOMELAB_BRANCH"
  git cat-file -e "origin/$HOMELAB_BRANCH:hosts/$name.env" 2>/dev/null ||
    die "hosts/$name.env isn't on origin/$HOMELAB_BRANCH; commit and push it first"
  git diff --quiet "origin/$HOMELAB_BRANCH" -- hosts/common.env "hosts/$name.env" ||
    die "hosts/common.env or hosts/$name.env differs from origin/$HOMELAB_BRANCH; commit and push it first"

  env_file="$(mktemp)"
  # shellcheck disable=SC2064  # expand now: env_file is global and may be reused
  trap "rm -f '$env_file'" EXIT
  {
    echo "HOST_NAME=$name"
    cat hosts/secrets.env
    [[ ! -f "hosts/$name.secrets.env" ]] || cat "hosts/$name.secrets.env"
  } >"$env_file"

  # Only these files, regardless of anything set in this shell.
  unset COMPOSE_FILE COMPOSE_PROFILES
  export COMPOSE_ENV_FILES
  COMPOSE_ENV_FILES="$(host_env_files "$name" "$env_file")"
  docker compose config --quiet || die "hosts/$name.env with your secrets doesn't produce a valid compose config"
  load_host_env
  placeholders="$(placeholder_keys)"
  [[ -z "$placeholders" ]] || die "your secrets still have placeholder values: $placeholders"
  target="$(env_get HOST_SSH)"
  target="${target:-$name.local}"
  log "host $name at $target, profiles: $(env_get COMPOSE_PROFILES)"
}

# host_provisioned: whether bootstrap.sh has completed on target.
host_provisioned() {
  local state
  # shellcheck disable=SC2029  # expanded locally on purpose
  state="$(ssh "$target" "test -f $BOOTSTRAP_STATE && echo yes || echo no")" || die "can't reach $target over ssh"
  [[ "$state" == yes ]]
}

# deploy_on_host COMMANDS: run COMMANDS on target, then a sync, and show how
# it went. One session, so sudo prompts at most once.
deploy_on_host() {
  # shellcheck disable=SC2029  # expanded locally on purpose
  ssh -t "$target" "
    $1
    echo; echo 'deploying...'
    sudo systemctl start homelab-sync.service; rc=\$?
    sudo journalctl -u homelab-sync -n 30 -o cat --no-pager | grep -E '\[(homelab|bootstrap)\]' | tail -8
    exit \$rc
  "
}
