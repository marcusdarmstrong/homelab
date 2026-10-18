#!/usr/bin/env bash
# Provision a freshly imaged host from its env file in this checkout.
#
#   scripts/provision.sh <name>     uses hosts/<name>.env
#
# Once per image. Copies bootstrap.sh over, which installs Docker, clones this
# repo's origin, installs the .env and enables the deploy timer, then runs the
# first deploy and shows the result. After that, commits deploy themselves and
# config changes go out with scripts/push-env.sh; this refuses a host that's
# already provisioned.
#
# Reaches the host at HOST_SSH from the file (default: <name>.local). sudo
# may prompt for a password.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"
cd "$REPO_DIR"

name="${1:?usage: provision.sh <name>   (reads hosts/<name>.env)}"
load_host_file "$name"
if host_provisioned; then
  die "$name is already provisioned; push config changes with scripts/push-env.sh $name"
fi

repo="${HOMELAB_REPO:-$(git remote get-url origin | sed -E 's#^git@github\.com:#https://github.com/#')}"
log "bootstrapping from $repo"
bootstrap=/tmp/homelab-bootstrap.sh
scp -q scripts/bootstrap.sh "$target:$bootstrap"
remote_tmp="$(ssh "$target" mktemp)"
scp -q "$env_file" "$target:$remote_tmp"

deploy_on_host "
  sudo $bootstrap --repo $repo --env $remote_tmp; rc=\$?; rm -f $remote_tmp $bootstrap
  [ \$rc -eq 0 ] || exit \$rc"
