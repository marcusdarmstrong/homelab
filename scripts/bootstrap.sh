#!/usr/bin/env bash
# Provision a Raspberry Pi (64-bit Raspberry Pi OS Lite) as a homelab host.
#
# Idempotent: every step inspects current state and only changes what differs,
# so re-running is always safe and is how you apply changes to this script.
#
# Usually run for you by scripts/provision.sh from your checkout. Directly
# (as root; works standalone or from a checkout):
#   bootstrap.sh --repo https://github.com/<you>/homelab.git [--env ./host.env]
#                [--branch main] [--dir /opt/homelab]
set -euo pipefail

REPO_URL=""
BRANCH=main
REPO_DIR=/opt/homelab
ENV_SRC=""

log() { printf '\033[1m[bootstrap]\033[0m %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

while (($#)); do
  case "$1" in
    --repo) REPO_URL="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --dir) REPO_DIR="$2"; shift 2 ;;
    --env) ENV_SRC="$(realpath "$2")"; shift 2 ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root (sudo $0 ...)"
[[ "$(dpkg --print-architecture)" == arm64 ]] || die "use 64-bit Raspberry Pi OS (this is $(dpkg --print-architecture))"
# Raspberry Pi OS manages the network, and so the Pi's own DNS, with it.
systemctl is-active --quiet NetworkManager || die "NetworkManager isn't running; only Raspberry Pi OS is supported"
# shellcheck source=/dev/null
source /etc/os-release

reboot_reasons=()

# write_file PATH CONTENT [MODE]: write only if different. Returns 0 if changed.
write_file() {
  local path="$1" content="$2" mode="${3:-0644}"
  if [[ -f "$path" && "$(cat "$path")" == "$content" ]]; then
    return 1
  fi
  install -d "$(dirname "$path")"
  printf '%s\n' "$content" >"$path"
  chmod "$mode" "$path"
  log "wrote $path"
}

apt_updated=0
apt_install() {
  local missing=() pkg
  for pkg in "$@"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
  done
  ((${#missing[@]})) || return 0
  if ((apt_updated == 0)); then
    apt-get update -q
    apt_updated=1
  fi
  log "installing ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends "${missing[@]}"
}

# ---- base packages -------------------------------------------------------------
apt_install ca-certificates curl git gnupg unattended-upgrades

# ---- docker (from Docker's apt repo, not the distro's) ---------------------
if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/debian/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
if write_file /etc/apt/sources.list.d/docker.list \
  "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $VERSION_CODENAME stable"; then
  apt_updated=0
fi
apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# daemon.json depends on .env, so it's written further down.
systemctl enable --now docker >/dev/null 2>&1
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] && ! id -nG "$SUDO_USER" | grep -qw docker; then
  usermod -aG docker "$SUDO_USER"
  log "added $SUDO_USER to the docker group (takes effect on next login)"
fi

# ---- kernel: memory cgroup (needed for container memory metrics/limits) -------
if ! grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
  cmdline=/boot/firmware/cmdline.txt
  [[ -f $cmdline ]] || cmdline=/boot/cmdline.txt
  if [[ -f $cmdline ]] && ! grep -qw cgroup_memory=1 "$cmdline"; then
    sed -i '1 s/$/ cgroup_enable=memory cgroup_memory=1/' "$cmdline"
    log "enabled memory cgroup in $cmdline"
  fi
  reboot_reasons+=("memory cgroup")
fi

# ---- swap: zram only -------------------------------------------------------------
# Raspberry Pi OS defaults to zram plus a 2 GB file on disk that idle pages
# get written back to daily. Plain zram keeps swap in RAM: no card writes.
if [[ -d /etc/rpi ]]; then
  if write_file /etc/rpi/swap.conf.d/homelab.conf '[Main]
Mechanism=zram'; then
    reboot_reasons+=("zram-only swap")
  fi
  # After that reboot the writeback file is detached and can go.
  if [[ -f /var/swap ]] && ! losetup -j /var/swap | grep -q . && ! grep -q '^/var/swap' /proc/swaps; then
    rm -f /var/swap
    log "removed the unused /var/swap writeback file"
  fi
fi

# Subnet routing for the tailscale profile. (IPv4 only: enabling IPv6
# forwarding would stop the Pi accepting router advertisements.)
if write_file /etc/sysctl.d/99-homelab.conf 'net.ipv4.ip_forward = 1'; then
  sysctl --quiet --system
fi

install -d /var/lib/homelab/metrics

# ---- repo checkout ---------------------------------------------------------------
if [[ -d "$REPO_DIR/.git" ]]; then
  existing="$(git -C "$REPO_DIR" remote get-url origin)"
  [[ -z "$REPO_URL" || "$REPO_URL" == "$existing" ]] ||
    die "$REPO_DIR already tracks $existing, not $REPO_URL"
  REPO_URL="$existing"
else
  [[ -n "$REPO_URL" ]] || die "--repo is required on first run"
fi

# The repo is public, so an anonymous HTTPS clone needs no credentials.
if [[ ! -d "$REPO_DIR/.git" ]]; then
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
  log "cloned $REPO_URL into $REPO_DIR"
fi
# Let non-root users read the root-owned checkout (git log, git status).
git config --system --get-all safe.directory 2>/dev/null | grep -qxF "$REPO_DIR" ||
  git config --system --add safe.directory "$REPO_DIR"

# ---- host config (.env) ------------------------------------------------------------
env_ready=1
if [[ -n "$ENV_SRC" ]]; then
  write_file "$REPO_DIR/.env" "$(cat "$ENV_SRC")" 0600 || true
elif [[ ! -f "$REPO_DIR/.env" ]]; then
  install -m 0600 "$REPO_DIR/.env.example" "$REPO_DIR/.env"
  log "created $REPO_DIR/.env from the example"
fi

cd "$REPO_DIR"
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
load_host_env || die "$REPO_DIR/.env doesn't produce a valid compose config"
# apply.sh, run below, picks the env files itself.
unset COMPOSE_ENV_FILES
# Placeholders from .env.example mean it isn't filled in.
[[ -z "$(placeholder_keys)" ]] || env_ready=0

# ---- hostname and host DNS (from .env) ----------------------------------------------
if ((env_ready)); then
  host_name="$(env_get HOST_NAME)"
  if [[ -n "$host_name" && "$(hostnamectl --static)" != "$host_name" ]]; then
    hostnamectl set-hostname "$host_name"
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
      sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$host_name/" /etc/hosts
    else
      printf '127.0.1.1\t%s\n' "$host_name" >>/etc/hosts
    fi
    log "hostname set to $host_name"
  fi

  # The Pi resolves via fixed upstreams, never its own Pi-hole, so it can
  # always pull images and sync git, even while Pi-hole is down.
  read -ra host_dns <<<"$(env_get HOST_DNS)"
  ((${#host_dns[@]})) || host_dns=(1.1.1.1 1.0.0.1)

  # Every active connection on a physical NIC, or DHCP DNS from the others
  # would still end up in resolv.conf. (Docker's veths also look like
  # ethernet, but have no backing device.)
  want="$(IFS=,; echo "${host_dns[*]}")|yes|yes"
  while IFS=: read -r con _ dev; do
    [[ -e "/sys/class/net/$dev/device" ]] || continue
    have="$(nmcli -g ipv4.dns,ipv4.ignore-auto-dns,ipv6.ignore-auto-dns connection show "$con" | paste -sd'|' -)"
    if [[ "$have" != "$want" ]]; then
      nmcli connection modify "$con" ipv4.dns "${host_dns[*]}" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes
      nmcli device reapply "$dev"
      log "set DNS on '$con' to ${host_dns[*]}"
    fi
  done < <(nmcli -t -f NAME,TYPE,DEVICE connection show --active)
  getent hosts github.com >/dev/null || log "warning: DNS lookups are failing after the DNS change"
fi

# ---- OS auto-updates ------------------------------------------------------------------
# Everything from Debian, Raspberry Pi (kernel, firmware, bootloader) and
# Docker, not just Debian security. Runs at OS_UPGRADE_TIME, after the 03:30
# backup, and reboots at OS_REBOOT_TIME only when an update needs it.
# Docker engine upgrades don't stop containers (live-restore); a reboot
# means a minute or two without DNS from this Pi.
upgrade_time="$(env_get OS_UPGRADE_TIME)"
reboot_time="$(env_get OS_REBOOT_TIME)"
auto_reboot="$(env_get OS_AUTO_REBOOT)"

write_file /etc/apt/apt.conf.d/20auto-upgrades 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";' || true

# Lists here add to the stock 50unattended-upgrades origins.
write_file /etc/apt/apt.conf.d/52homelab-unattended-upgrades "Unattended-Upgrade::Origins-Pattern {
  \"origin=Debian,codename=\${distro_codename},label=Debian\";
  \"origin=Debian,codename=\${distro_codename}-updates,label=Debian\";
  \"origin=Debian,codename=\${distro_codename}-security,label=Debian-Security\";
  \"origin=Raspberry Pi Foundation,codename=\${distro_codename}\";
  \"origin=Docker,label=Docker CE\";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages \"true\";
Unattended-Upgrade::Remove-Unused-Dependencies \"true\";
Unattended-Upgrade::Automatic-Reboot \"${auto_reboot:-true}\";
Unattended-Upgrade::Automatic-Reboot-WithUsers \"true\";
Unattended-Upgrade::Automatic-Reboot-Time \"${reboot_time:-04:30}\";
Unattended-Upgrade::SyslogEnable \"true\";" || true

if write_file /etc/systemd/system/apt-daily-upgrade.timer.d/homelab.conf "[Timer]
OnCalendar=
OnCalendar=*-*-* ${upgrade_time:-04:00}
RandomizedDelaySec=0"; then
  systemctl daemon-reload
  systemctl restart apt-daily-upgrade.timer
fi
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1

# ---- docker daemon -------------------------------------------------------------
# live-restore keeps containers (Pi-hole especially) running across dockerd
# restarts. Container logs reach Loki either way; DOCKER_LOG_DRIVER (set by
# config/sdcard.env) picks where Docker keeps its own copy: "local" (rotated
# files on disk) or "journald" (the journal, which Raspberry Pi OS keeps in
# RAM).
log_driver="$(env_get DOCKER_LOG_DRIVER)"
case "${log_driver:=local}" in
  local) log_opts=$',\n  "log-opts": { "max-size": "10m", "max-file": "3" }' ;;
  journald) log_opts="" ;;
  *) die "DOCKER_LOG_DRIVER must be local or journald, not '$log_driver'" ;;
esac
recreate=0
if write_file /etc/docker/daemon.json "{
  \"log-driver\": \"$log_driver\"$log_opts,
  \"live-restore\": true
}"; then
  systemctl restart docker
  # A container's log driver is fixed when it's created.
  if docker ps -aq --filter label=com.docker.compose.project=homelab | grep -q .; then
    recreate=1
  fi
fi

# ---- deploy timer ------------------------------------------------------------------
units_changed=0
for unit in homelab-sync.service homelab-sync.timer; do
  rendered="$(sed -e "s|@REPO_DIR@|$REPO_DIR|g" "$REPO_DIR/systemd/$unit")"
  write_file "/etc/systemd/system/$unit" "$rendered" && units_changed=1
done
if [[ "$BRANCH" != main ]]; then
  write_file /etc/systemd/system/homelab-sync.service.d/branch.conf "[Service]
Environment=HOMELAB_BRANCH=$BRANCH" && units_changed=1
fi
((units_changed)) && systemctl daemon-reload

# Deploying with placeholder values would request certificates with fake
# credentials, so hold off until .env has been filled in.
if ((env_ready)); then
  systemctl enable --now homelab-sync.timer >/dev/null 2>&1
  if ((recreate)); then
    log "recreating containers for the new log driver"
    HOMELAB_FORCE_RECREATE=1 "$REPO_DIR/scripts/apply.sh"
  fi
  systemctl start --no-block homelab-sync.service
  log "deploy timer enabled; follow with: journalctl -fu homelab-sync"
else
  log "fill in the placeholders in $REPO_DIR/.env (or pass --env), then re-run to enable deploys"
fi

if ((${#reboot_reasons[@]})); then
  printf -v reasons '%s, ' "${reboot_reasons[@]}"
  log "reboot required: ${reasons%, }"
fi
log "done"
