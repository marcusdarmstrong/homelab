#!/usr/bin/env bash
# Provision or update a host from its env file in this checkout.
#
#   scripts/provision.sh <name>     uses hosts/<name>.env
#
# hosts/<name>.env (gitignored) is the source of truth for that host's
# config. Keep it here, back it up to your password manager, and change it
# only here: each run overwrites the host's own .env.
#
# Each run validates the file, shows which keys differ from the host's copy,
# installs it through bootstrap.sh (which also applies host-level settings
# such as DNS and update times), then deploys and shows the result. A fresh
# host gets bootstrap.sh copied over first and clones this repo's origin.
#
# Reaches the host at HOST_SSH from the file (default: <name>.local). sudo
# may prompt for a password.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"
cd "$REPO_DIR"

name="${1:?usage: provision.sh <name>   (reads hosts/<name>.env)}"
env_file="hosts/$name.env"
[[ -f "$env_file" ]] || die "no $env_file (start from .env.example and scripts/gen-secrets.sh)"

# ---- validate locally ---------------------------------------------------------------
if grep -qiE "^[A-Z0-9_]+=[\"']?change-?me" "$env_file"; then
  die "$env_file still has placeholder values: $(grep -iE "^[A-Z0-9_]+=[\"']?change-?me" "$env_file" | cut -d= -f1 | tr '\n' ' ')"
fi
# Only the host's file, regardless of anything set in this shell.
local_compose() { env -u COMPOSE_FILE -u COMPOSE_ENV_FILES -u COMPOSE_PROFILES docker compose --env-file "$env_file" "$@"; }
local_compose config --quiet || die "$env_file doesn't produce a valid compose config"
env_get() { local_compose config --environment | sed -n "s/^$1=//p"; }

target="$(env_get HOST_SSH)"
target="${target:-$name.local}"
log "host $name at $target, profiles: $(env_get COMPOSE_PROFILES)"

# ---- show what changes ------------------------------------------------------------
# Compare per-key checksums so no values are printed.
key_sums() {
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | while IFS= read -r line; do
    printf '%s %s\n' "${line%%=*}" "$(printf '%s' "${line#*=}" | cksum | cut -d' ' -f1)"
  done | sort
}
remote_env="$(ssh "$target" 'sudo -n cat /opt/homelab/.env 2>/dev/null' || true)"
if [[ -z "$remote_env" ]]; then
  log "no readable .env on the host yet (new host, or sudo needs a password)"
else
  changes="$(join -a1 -a2 -e - -o 0,1.2,2.2 <(key_sums <<<"$remote_env") <(key_sums <"$env_file") |
    awk '$2 == "-" { print "+" $1 } $3 == "-" { print "-" $1 } $2 != "-" && $3 != "-" && $2 != $3 { print "~" $1 }')"
  log "changes: $(echo "${changes:-none}" | tr '\n' ' ')"
fi

# ---- install and deploy ------------------------------------------------------------
bootstrap=/opt/homelab/scripts/bootstrap.sh
repo_args=()
# shellcheck disable=SC2029  # expanded locally on purpose
if ! ssh "$target" "test -x $bootstrap"; then
  bootstrap=/tmp/homelab-bootstrap.sh
  scp -q scripts/bootstrap.sh "$target:$bootstrap"
  repo="${HOMELAB_REPO:-$(git remote get-url origin | sed -E 's#^git@github\.com:#https://github.com/#')}"
  repo_args=(--repo "$repo")
  log "new host: bootstrapping from $repo"
fi

remote_tmp="$(ssh "$target" mktemp)"
scp -q "$env_file" "$target:$remote_tmp"

# One session, so sudo prompts at most once.
# shellcheck disable=SC2029  # expanded locally on purpose
ssh -t "$target" "
  sudo $bootstrap ${repo_args[*]} --env $remote_tmp; rc=\$?; rm -f $remote_tmp
  [ \$rc -eq 0 ] || exit \$rc
  systemctl is-enabled --quiet homelab-sync.timer || exit 0
  echo; echo 'deploying...'
  sudo systemctl start homelab-sync.service; rc=\$?
  sudo journalctl -u homelab-sync -n 30 -o cat --no-pager | grep -F '[homelab]' | tail -6
  exit \$rc
"
