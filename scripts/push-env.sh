#!/usr/bin/env bash
# Push a host's env file from this checkout and deploy it.
#
#   scripts/push-env.sh <name>     uses hosts/<name>.env
#
# hosts/<name>.env (gitignored) is the source of truth for that host's
# config. Keep it here, back it up to your password manager, and change it
# only here: each push overwrites the host's own .env.
#
# Validates the file, shows which keys differ from the host's copy (no values
# are printed), installs it and runs a sync, which applies it (host-level
# settings included) and shows the result. The host must already be
# provisioned (scripts/provision.sh).
#
# Reaches the host at HOST_SSH from the file (default: <name>.local). sudo
# may prompt for a password.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"
cd "$REPO_DIR"

name="${1:?usage: push-env.sh <name>   (reads hosts/<name>.env)}"
load_host_file "$name"
host_provisioned || die "$name isn't provisioned yet; run scripts/provision.sh $name"

# ---- show what changes ------------------------------------------------------------
# Compare per-key checksums so no values are printed.
key_sums() {
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | while IFS= read -r line; do
    printf '%s %s\n' "${line%%=*}" "$(printf '%s' "${line#*=}" | cksum | cut -d' ' -f1)"
  done | sort
}
remote_env="$(ssh "$target" 'sudo -n cat /opt/homelab/.env 2>/dev/null' || true)"
if [[ -z "$remote_env" ]]; then
  log "can't read the host's .env without a sudo password; pushing without a diff"
else
  changes="$(join -a1 -a2 -e - -o 0,1.2,2.2 <(key_sums <<<"$remote_env") <(key_sums <"$env_file") |
    awk '$2 == "-" { print "+" $1 } $3 == "-" { print "-" $1 } $2 != "-" && $3 != "-" && $2 != $3 { print "~" $1 }')"
  [[ -n "$changes" ]] || { log "no changes to push"; exit 0; }
  log "changes: $(echo "$changes" | tr '\n' ' ')"
fi

# ---- install and deploy ------------------------------------------------------------
remote_tmp="$(ssh "$target" mktemp)"
scp -q "$env_file" "$target:$remote_tmp"

deploy_on_host "
  sudo install -m 0600 $remote_tmp /opt/homelab/.env; rc=\$?; rm -f $remote_tmp
  [ \$rc -eq 0 ] || exit \$rc"
