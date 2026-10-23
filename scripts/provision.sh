#!/usr/bin/env bash
# Provision a freshly imaged host.
#
#   scripts/provision.sh <name>
#
# hosts/<name>.env must already be committed and pushed: the host reads its
# settings from git. Its .env (HOST_NAME plus your secrets from
# hosts/secrets.env and hosts/<name>.secrets.env) goes over ssh.
#
# Image an SD card with Raspberry Pi Imager, even for a host that runs from
# an NVMe drive: when the settings say HOST_STORAGE=ssd and the host booted
# from its card, this first installs onto the NVMe (scripts/move-to-nvme.sh)
# and waits for it to boot from there. It asks before erasing an NVMe that
# isn't blank.
#
# Once per image. Copies bootstrap.sh over, which installs Docker, clones this
# repo's origin, installs the .env and enables the deploy timer, then runs the
# first deploy and shows the result. After that, commits deploy themselves and
# secret changes go out with scripts/push-env.sh; this refuses a host that's
# already provisioned.
#
# Reaches the host at HOST_SSH from its host file (default: <name>.local).
# sudo may prompt for a password.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"
cd "$REPO_DIR"

name="${1:?usage: provision.sh <name>}"
load_host_file "$name"
if host_provisioned; then
  die "$name is already provisioned; push config changes with scripts/push-env.sh $name"
fi

# booted_from: the host's root device, or nothing while it's unreachable.
booted_from() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" findmnt -no SOURCE / 2>/dev/null || true; }

if [[ "$(env_get HOST_STORAGE)" != sdcard && "$(booted_from)" == /dev/mmcblk* ]]; then
  ssh "$target" test -b /dev/nvme0n1 ||
    die "$name booted from its SD card and has no NVMe drive; install one, or set HOST_STORAGE=sdcard in hosts/$name.env"
  wipe=""
  if (($(ssh "$target" lsblk -no NAME /dev/nvme0n1 | wc -l) > 1)); then
    read -rp "$name's NVMe isn't blank. Erase it and install a fresh system? [y/N] " answer
    [[ "$answer" == [yY]* ]] || die "stopped; nothing changed"
    wipe=--wipe
  fi
  log "installing onto $name's NVMe"
  scp -q scripts/move-to-nvme.sh "$target:/tmp/homelab-move-to-nvme.sh"
  ssh -t "$target" "sudo bash /tmp/homelab-move-to-nvme.sh $wipe"

  log "waiting for $name to boot from its NVMe and finish first-boot setup"
  sleep 30
  for ((i = 0; ; i++)); do
    # cloud-init status exits 2 when it finished with only warnings.
    if [[ "$(booted_from)" == /dev/nvme* ]] &&
      ssh -o BatchMode=yes "$target" 'cloud-init status --wait >/dev/null; [ $? -ne 1 ]'; then
      break
    fi
    ((i < 60)) || die "$name didn't come back from its NVMe within 10 minutes"
    sleep 10
  done
  log "$name is running from its NVMe"
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
